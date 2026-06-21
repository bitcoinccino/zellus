class CheckoutsController < ApplicationController
  before_action :authenticate_user!, except: [ :show ]
  before_action :set_checkout

  def show
    @checkout.mark_expired_if_needed!

    unless user_signed_in?
      store_location_for(:user, request.fullpath)
    end

    if user_signed_in?
      @pin_set = current_user.transfer_pin_set?
      wallet = current_user.ensure_wallet!
      @payer_balance = wallet.balance_for(@checkout.currency)
      @balance_shortfall = [ (@checkout.amount - @payer_balance), 0 ].max
      @can_pay = @pin_set && @payer_balance >= @checkout.amount
    end
  end

  def confirm
    unless @checkout.pending?
      redirect_to checkout_pay_path(@checkout.token), alert: "Sesyon sa a pa aktif ankò."
      return
    end

    if @checkout.expired_now?
      @checkout.mark_expired_if_needed!
      redirect_to checkout_pay_path(@checkout.token), alert: "Sesyon sa a ekspire."
      return
    end

    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to checkout_pay_path(@checkout.token), alert: "PIN pa kòrèk."
      return
    end

    receiver = @checkout.receiver_user
    unless receiver
      redirect_to checkout_pay_path(@checkout.token), alert: "Resevè pa jwenn."
      return
    end

    if receiver.id == current_user.id
      redirect_to checkout_pay_path(@checkout.token), alert: "Ou pa ka peye tèt ou."
      return
    end

    payer_wallet = current_user.ensure_wallet!
    receiver_wallet = receiver.ensure_wallet!
    amount = @checkout.amount
    asset = @checkout.currency

    unless payer_wallet.sufficient_balance?(asset, amount)
      redirect_to checkout_pay_path(@checkout.token), alert: "Balans pa sifi."
      return
    end

    ActiveRecord::Base.transaction do
      transfer = Transfer.create!(
        user: current_user,
        receiver_cashtag: receiver.cashtag,
        receiver_name: receiver.display_name,
        amount: amount,
        asset: asset,
        status: :completed,
        note: @checkout.description,
        payout_method: "wallet",
        funded_at: Time.current
      )

      WalletService.new(payer_wallet).transfer_out!(
        amount: amount, fee: 0, transfer: transfer, asset: asset
      )

      WalletService.new(receiver_wallet).transfer_in!(
        amount: amount, transfer: transfer, sender_user: current_user, asset: asset
      )

      @checkout.update!(
        status: :completed,
        payer: current_user,
        transfer: transfer,
        completed_at: Time.current
      )

      NotificationService.transfer_received(transfer)
      NotificationService.transfer_completed(transfer)
    end

    WebhookService.dispatch("checkout.completed", user: @checkout.receiver_user, payload: {
      checkout_token: @checkout.token,
      transfer_token: @checkout.transfer.token,
      amount: @checkout.amount.to_s,
      currency: @checkout.currency,
      payer_cashtag: "$#{current_user.cashtag}",
      metadata: @checkout.metadata
    })

    redirect_url = @checkout.success_url
    separator = redirect_url.include?("?") ? "&" : "?"
    redirect_to "#{redirect_url}#{separator}checkout_token=#{@checkout.token}&status=completed", allow_other_host: true
  rescue WalletService::InsufficientFundsError
    redirect_to checkout_pay_path(@checkout.token), alert: "Balans pa sifi."
  rescue => e
    Rails.logger.error "Checkout#confirm failed: #{e.message}"
    redirect_to checkout_pay_path(@checkout.token), alert: "Yon erè rive. Eseye ankò."
  end

  def cancel
    if @checkout.pending?
      @checkout.update!(status: :canceled)
    end

    if @checkout.cancel_url.present?
      separator = @checkout.cancel_url.include?("?") ? "&" : "?"
      redirect_to "#{@checkout.cancel_url}#{separator}checkout_token=#{@checkout.token}&status=canceled", allow_other_host: true
    else
      redirect_to checkout_pay_path(@checkout.token), notice: "Peman anile."
    end
  end

  private

  def set_checkout
    @checkout = CheckoutSession.find_by!(token: params[:token])
  end
end

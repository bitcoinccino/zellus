class PaymentRequestsController < ApplicationController
  before_action :authenticate_user!, except: [:public_show]
  before_action :set_payment_request, only: [:show, :update, :destroy]

  def index
    @payment_requests = current_user.payment_requests.recent_first
  end

  def new
    @payment_request = current_user.payment_requests.new(asset: :htg, status: :active)
  end

  def create
    @payment_request = current_user.payment_requests.new(payment_request_params)
    @payment_request.status = :active
    @payment_request.expires_at = 48.hours.from_now.change(sec: 0)

    if @payment_request.save
      PaymentRequestMailer.with(payment_request_id: @payment_request.id).request_created.deliver_later

      # Notify the payer if they're a known user
      if @payment_request.payer_id.present?
        PaymentRequestMailer.with(payment_request_id: @payment_request.id).payer_request_received.deliver_later
        NotificationService.payment_request_received(@payment_request)
      end

      redirect_to payment_request_path(@payment_request), notice: "Demann peman kreye."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @payment_request.mark_expired_if_needed!
    @share_url = public_payment_request_url(@payment_request.token)
  end

  def update
    if params[:mark_paid].present?
      @payment_request.update!(status: :paid)
      PaymentRequestMailer.with(payment_request_id: @payment_request.id).request_paid.deliver_later
      NotificationService.payment_request_paid(@payment_request)
      redirect_to payment_request_path(@payment_request), notice: "Demann peman make kòm peye."
    elsif params[:cancel].present?
      cancel_note = params[:cancel_note].to_s.strip
      if cancel_note.blank?
        redirect_to payment_request_path(@payment_request), alert: "Ou dwe bay yon rezon pou anile."
        return
      end
      @payment_request.update!(status: :canceled, cancel_note: cancel_note)
      PaymentRequestMailer.with(payment_request_id: @payment_request.id).request_canceled.deliver_later
      NotificationService.payment_request_canceled(@payment_request)
      redirect_to payment_request_path(@payment_request), notice: "Demann peman anile."
    else
      redirect_to payment_request_path(@payment_request), alert: "Pa gen aksyon chwazi."
    end
  end

  def destroy
    @payment_request.destroy!
    redirect_to payment_requests_path, notice: "Demann peman efase."
  end

  def dismiss
    @payment_request = PaymentRequest.find_by!(token: params[:token])

    unless @payment_request.active? && @payment_request.payer_id == current_user.id
      redirect_to wallet_path, alert: "Ou pa ka kache demann sa a."
      return
    end

    @payment_request.update!(payer_id: nil)
    redirect_to wallet_path, notice: "Demann peman kache."
  end

  def pay
    @payment_request = PaymentRequest.find_by!(token: params[:token])

    unless @payment_request.active?
      redirect_to public_payment_request_path(@payment_request.token), alert: "Demann sa a pa aktif ankò."
      return
    end

    if @payment_request.user_id == current_user.id
      redirect_to public_payment_request_path(@payment_request.token), alert: "Ou pa ka peye pwòp demann ou."
      return
    end

    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to public_payment_request_path(@payment_request.token), alert: "PIN pa kòrèk."
      return
    end

    payer_wallet = current_user.ensure_wallet!
    creator = @payment_request.user
    creator_wallet = creator.ensure_wallet!
    amount = @payment_request.amount
    asset = @payment_request.asset

    unless payer_wallet.sufficient_balance?(asset, amount)
      redirect_to public_payment_request_path(@payment_request.token), alert: "Balans pa sifi."
      return
    end

    ActiveRecord::Base.transaction do
      # Create transfer record
      transfer = Transfer.create!(
        user: current_user,
        receiver_cashtag: creator.cashtag,
        receiver_name: creator.display_name,
        amount: amount,
        asset: asset,
        status: :completed,
        note: @payment_request.note,
        payout_method: "wallet",
        funded_at: Time.current
      )

      # Debit payer
      WalletService.new(payer_wallet).transfer_out!(
        amount: amount, fee: 0, transfer: transfer, asset: asset
      )

      # Credit creator
      WalletService.new(creator_wallet).transfer_in!(
        amount: amount, transfer: transfer, sender_user: current_user, asset: asset
      )

      # Mark request as paid
      @payment_request.update!(status: :paid, payer_id: current_user.id)

      # Notifications & emails
      NotificationService.transfer_received(transfer)
      NotificationService.transfer_completed(transfer)
      NotificationService.payment_request_paid(@payment_request)
      PaymentRequestMailer.with(payment_request_id: @payment_request.id).request_paid.deliver_later
    end

    redirect_to public_payment_request_path(@payment_request.token), notice: "Peman reyisi! Ou voye #{amount} #{asset.upcase} bay #{creator.display_name}."
  rescue WalletService::InsufficientFundsError
    redirect_to public_payment_request_path(@payment_request.token), alert: "Balans pa sifi."
  rescue => e
    Rails.logger.error "PaymentRequest#pay failed: #{e.message}"
    redirect_to public_payment_request_path(@payment_request.token), alert: "Yon erè rive. Eseye ankò."
  end

  def public_show
    @payment_request = PaymentRequest.find_by!(token: params[:token])
    @payment_request.mark_expired_if_needed!
    @share_url = public_payment_request_url(@payment_request.token)

    if user_signed_in?
      @is_creator = @payment_request.user_id == current_user.id
      @pin_set = current_user.transfer_pin_set?

      unless @is_creator
        wallet = current_user.ensure_wallet!
        @payer_balance = wallet.balance_for(@payment_request.asset)
        @balance_shortfall = [(@payment_request.amount - @payer_balance), 0].max
        @can_pay_direct = @pin_set && @payer_balance >= @payment_request.amount
      end
    end
  end

  private

  def set_payment_request
    @payment_request = current_user.payment_requests.find(params[:id])
  end

  def payment_request_params
    params.require(:payment_request).permit(:asset, :amount, :payer_name, :payer_id, :note)
  end

  def default_request_expiration_time
    48.hours.from_now.change(sec: 0)
  end

end

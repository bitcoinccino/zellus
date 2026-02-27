class TransfersController < ApplicationController
  before_action :authenticate_user!, except: [:claim, :claim_confirm]

  # ── GET /transfers/new ──
  def new
    @transfer = current_user.transfers.new
    @daily_remaining = current_user.daily_transfer_remaining
    load_saved_methods
    load_rates
  end

  # ── POST /transfers/set_pin — Set transfer PIN ──
  def set_pin
    pin = params[:transfer_pin].to_s.strip
    unless pin.match?(/\A\d{4}\z/)
      flash[:alert] = "PIN dwe 4 chif."
      redirect_to new_transfer_path
      return
    end

    current_user.transfer_pin = pin
    current_user.save!
    flash[:notice] = "PIN transfè ou enstale avèk siksè!"
    redirect_to new_transfer_path
  end

  # ── POST /transfers ──
  def create
    @daily_remaining = current_user.daily_transfer_remaining
    load_saved_methods
    load_rates

    asset_type = params[:asset].to_s
    asset_type = "htg" unless %w[htg usdc eth].include?(asset_type)

    @transfer = current_user.transfers.new(transfer_params)
    @transfer.asset = asset_type

    # Resolve receiver from saved method or manual input
    resolve_receiver(@transfer, asset_type)

    # For crypto transfers, calculate crypto amount from HTG
    if @transfer.crypto_transfer?
      rate = exchange_rate_for(asset_type)
      if rate && rate > 0 && @transfer.amount.to_f > 0
        @transfer.exchange_rate = rate
        precision = asset_type == "wbtc" ? 8 : (asset_type == "eth" ? 8 : 6)
        @transfer.crypto_amount = (@transfer.amount.to_f / rate).round(precision)
      end
    end

    # PIN not required here — it's checked on the show page before confirming
    # But PIN must be set
    unless current_user.transfer_pin_set?
      flash.now[:alert] = "Ou dwe kreye yon PIN transfè anvan ou voye lajan."
      render :new, status: :unprocessable_entity
      return
    end

    # Per-transaction limits
    if send_limit_error(@transfer.amount).present?
      flash.now[:alert] = send_limit_error(@transfer.amount)
      render :new, status: :unprocessable_entity
      return
    end

    # Daily limit check
    if daily_limit_error(@transfer.amount).present?
      flash.now[:alert] = daily_limit_error(@transfer.amount)
      render :new, status: :unprocessable_entity
      return
    end

    unless @transfer.save
      render :new, status: :unprocessable_entity
      return
    end

    # Redirect to show page for PIN confirmation before payment
    redirect_to transfer_path(@transfer)
  end

  # ── GET /transfers/:id ──
  def show
    @transfer = current_user.transfers.find(params[:id])
    @claim_url = claim_transfer_url(@transfer.token)
    @needs_pin = @transfer.pending? && current_user.transfer_pin_set?
  end

  # ── POST /transfers/:id/confirm — PIN verification + initiate payment ──
  def confirm
    @transfer = current_user.transfers.find(params[:id])

    unless @transfer.pending?
      redirect_to transfer_path(@transfer), alert: "Transfè sa a deja konfime."
      return
    end

    # Verify PIN
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      flash[:alert] = "PIN pa kòrèk. Tanpri eseye ankò."
      redirect_to transfer_path(@transfer)
      return
    end

    # ── Wallet funding (HTG only) ──
    if @transfer.htg_transfer? && params[:funding_source] == "wallet"
      wallet = current_user.ensure_wallet!

      unless wallet.sufficient_balance?(@transfer.amount)
        redirect_to transfer_path(@transfer),
                    alert: "Balans pòtfèy pa sifi. Ou bezwen #{@transfer.amount.to_i} HTG men ou gen #{wallet.htg_balance.to_i} HTG."
        return
      end

      begin
        WalletService.new(wallet).transfer_out!(
          amount: @transfer.amount,
          fee: @transfer.fee,
          transfer: @transfer
        )
        @transfer.update!(
          status: :funded,
          funded_at: Time.current,
          funding_source: "wallet",
          expires_at: 72.hours.from_now
        )

        # Trigger payout
        TransferPayoutWorker.perform_async(@transfer.id) if @transfer.receiver_phone.present?

        # Emails
        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
          if @transfer.receiver_email.present?
            TransferMailer.with(transfer_id: @transfer.id).receiver_incoming.deliver_later
          end
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        TransferExpiryWorker.perform_in(73.hours, @transfer.id) if @transfer.htg_transfer?

        redirect_to transfer_path(@transfer), notice: "Transfè finansye nan pòtfèy ou! N ap voye lajan bay moun nan."
      rescue WalletService::InsufficientFundsError
        redirect_to transfer_path(@transfer), alert: "Balans pòtfèy pa sifi."
      rescue WalletService::FrozenAccountError
        redirect_to transfer_path(@transfer), alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
      end
      return
    end

    # ── MonCash funding (existing path) ──
    order_id = "transfer-#{@transfer.id}-#{Time.now.to_i}"
    url = create_moncash_payment(@transfer.amount.to_i, order_id)

    if url
      @transfer.update!(moncash_order_id: order_id, funding_source: "moncash")
      redirect_to url, allow_other_host: true
    else
      @transfer.update!(status: :failed, failure_reason: "MonCash pa disponib")
      redirect_to transfer_path(@transfer), alert: "MonCash pa disponib kounye a. Tanpri eseye ankò."
    end
  end

  # ── GET /transfers/:id/success — MonCash callback ──
  def success
    @transfer = current_user.transfers.find(params[:id])
    @claim_url = claim_transfer_url(@transfer.token)

    if @transfer.funded? || @transfer.sent? || @transfer.completed?
      flash.now[:notice] = "Peman an deja konfime."
    elsif @transfer.pending?
      verified = MoncashService.verify_order(@transfer.moncash_order_id)

      if verified
        @transfer.update!(status: :funded, funded_at: Time.current, expires_at: 72.hours.from_now)

        if @transfer.htg_transfer?
          # HTG payout via MonCash
          if @transfer.receiver_phone.present?
            TransferPayoutWorker.perform_async(@transfer.id)
          end
          # If no phone, receiver claims via /t/:token
        else
          # Crypto: send from treasury to receiver wallet
          TransferPayoutWorker.perform_async(@transfer.id)
        end

        begin
          TransferMailer.with(transfer_id: @transfer.id).sender_funded.deliver_later
          if @transfer.receiver_email.present?
            TransferMailer.with(transfer_id: @transfer.id).receiver_incoming.deliver_later
          end
        rescue => e
          Rails.logger.error "Transfer email failed [transfer=#{@transfer.id}]: #{e.message}"
        end

        TransferExpiryWorker.perform_in(73.hours, @transfer.id) if @transfer.htg_transfer?

        receiver_label = @transfer.receiver_name.presence || @transfer.receiver_display
        flash.now[:notice] = "Mèsi! Peman ou konfime. N ap voye #{@transfer.asset_label} bay #{receiver_label}."
      else
        flash.now[:alert] = "Nou pa t kapab verifye peman ou ak MonCash. Tanpri kontakte sipò."
      end
    else
      flash.now[:alert] = "Transfè sa a pa ka trete."
    end

    render :show
  end

  # ── GET /t/:token — Public claim page (no auth) ──
  def claim
    @transfer = Transfer.find_by!(token: params[:token])
    @transfer.mark_expired_if_needed!
  end

  # ── POST /t/:token/claim — Receiver submits MonCash number ──
  def claim_confirm
    @transfer = Transfer.find_by!(token: params[:token])
    @transfer.mark_expired_if_needed!

    unless @transfer.funded?
      flash[:alert] = case @transfer.status
                      when "completed" then "Transfè sa a deja konplete."
                      when "expired"   then "Transfè sa a ekspire."
                      when "claimed"   then "Transfè sa a deja reklame. N ap trete l."
                      else "Transfè sa a pa disponib."
                      end
      redirect_to claim_transfer_path(@transfer.token)
      return
    end

    phone = params[:receiver_phone].to_s.strip
    unless phone.match?(/\A509\d{8}\z/)
      flash[:alert] = "Tanpri antre yon nimewo MonCash valid (509 + 8 chif)."
      redirect_to claim_transfer_path(@transfer.token)
      return
    end

    @transfer.update!(receiver_phone: phone, status: :claimed)
    TransferPayoutWorker.perform_async(@transfer.id)

    flash[:notice] = "Nimewo MonCash ou anrejistre. N ap voye #{number_to_currency(@transfer.net_amount, unit: 'HTG ', precision: 0)} ba ou!"
    redirect_to claim_transfer_path(@transfer.token)
  end

  private

  def transfer_params
    params.require(:transfer).permit(:receiver_name, :receiver_phone, :receiver_email, :receiver_wallet_address, :amount, :note)
  end

  def load_saved_methods
    @moncash_methods = current_user.payment_methods.active.mobile_wallet.moncash.order(created_at: :desc)
    @crypto_methods  = current_user.payment_methods.active.crypto_wallet.base.order(created_at: :desc)
  end

  def load_rates
    @usdc_htg_rate = RateService.buy_rate        # HTG per 1 USDC
    @eth_htg_rate  = RateService.eth_htg_buy_rate # HTG per 1 ETH
    @wbtc_htg_rate = RateService.wbtc_htg_buy_rate # HTG per 1 WBTC
  rescue => e
    Rails.logger.error "TransfersController rate load failed: #{e.message}"
    @usdc_htg_rate = 135.50
    @eth_htg_rate  = 390_000.0
    @wbtc_htg_rate = 12_872_500.0
  end

  def exchange_rate_for(asset_type)
    case asset_type
    when "usdc" then @usdc_htg_rate
    when "eth"  then @eth_htg_rate
    when "wbtc" then @wbtc_htg_rate
    else nil
    end
  end

  def resolve_receiver(transfer, asset_type)
    if asset_type == "htg"
      # Check saved MonCash method
      method_id = params[:moncash_method_id].to_s.strip
      if method_id.present? && method_id != "other"
        method = current_user.payment_methods.active.mobile_wallet.find_by(id: method_id)
        transfer.receiver_phone = method.account_number if method
      end
      # Manual phone takes precedence if provided
      manual_phone = params.dig(:transfer, :receiver_phone).to_s.strip
      transfer.receiver_phone = manual_phone if manual_phone.present?
    else
      # Check saved crypto wallet
      method_id = params[:crypto_method_id].to_s.strip
      if method_id.present? && method_id != "other"
        method = current_user.payment_methods.active.crypto_wallet.find_by(id: method_id)
        transfer.receiver_wallet_address = method.wallet_address if method
      end
      # Manual address takes precedence if provided
      manual_addr = params.dig(:transfer, :receiver_wallet_address).to_s.strip
      transfer.receiver_wallet_address = manual_addr if manual_addr.present?
    end
  end

  def send_limit_error(amount)
    value = amount.to_f
    return "Antre yon montan valid." if value <= 0
    return "Montan minimòm se #{Transfer::SEND_MIN_HTG} HTG." if value < Transfer::SEND_MIN_HTG
    return "Montan maksimòm se #{number_with_delimiter(Transfer::SEND_MAX_HTG)} HTG pa tranzaksyon." if value > Transfer::SEND_MAX_HTG

    nil
  end

  def daily_limit_error(amount)
    remaining = current_user.daily_transfer_remaining
    limit     = User::DAILY_TRANSFER_LIMIT_HTG
    return nil if amount.to_f <= remaining

    "Ou depase limit jounalye ou (#{number_with_delimiter(limit.to_i)} HTG/jou). Ou ka voye #{number_with_delimiter(remaining.to_i)} HTG ankò jodi a."
  end

  def create_moncash_payment(amount, order_id)
    token = MoncashService.get_token
    return nil unless token

    base_url = MoncashService::BASE_URL
    gateway  = MoncashService::GATEWAY_BASE_URL

    conn = Faraday.new(url: "#{base_url}/Api/v1/CreatePayment")
    payload = { amount: amount.to_i, orderId: order_id }.to_json

    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Content-Type']  = 'application/json'
      req.headers['Accept']        = 'application/json'
      req.body = payload
    end

    if response.success?
      body = JSON.parse(response.body)
      payment_token = body.dig("payment_token", "token")
      "#{gateway}/Payment/Redirect?token=#{payment_token}"
    else
      Rails.logger.error "MonCash Transfer Payment Failed: #{response.status} #{response.body}"
      nil
    end
  rescue => e
    Rails.logger.error "MonCash Transfer Payment Error: #{e.message}"
    nil
  end
end

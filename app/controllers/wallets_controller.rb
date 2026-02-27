class WalletsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_wallet

  DEPOSIT_MIN  = 100
  DEPOSIT_MAX  = 50_000
  WITHDRAW_MIN = 100
  WITHDRAW_MAX = 50_000

  # ── GET /wallet ──
  def show
    @ledger_entries = @wallet.wallet_ledger_entries.recent_first.limit(25)
    @moncash_methods = current_user.payment_methods.active.mobile_wallet.moncash.order(created_at: :desc)
  end

  # ── POST /wallet/deposit ──
  def deposit
    amount = params[:amount].to_f

    if amount < DEPOSIT_MIN || amount > DEPOSIT_MAX
      redirect_to wallet_path, alert: "Montan depo dwe ant #{DEPOSIT_MIN} ak #{number_with_delimiter(DEPOSIT_MAX)} HTG."
      return
    end

    order_id = "wallet-deposit-#{current_user.id}-#{Time.now.to_i}"
    url = create_moncash_payment(amount.to_i, order_id)

    if url
      session[:wallet_deposit_order_id] = order_id
      session[:wallet_deposit_amount]   = amount
      redirect_to url, allow_other_host: true
    else
      redirect_to wallet_path, alert: "MonCash pa disponib kounye a. Tanpri eseye ankò."
    end
  end

  # ── GET /wallet/deposit_success — MonCash callback ──
  # MonCash redirects to /payment_success with ?transactionId=...&orderId=...
  # transactions#success detects "wallet-deposit-*" and redirects here.
  def deposit_success
    # Prefer session (set during POST /wallet/deposit), fall back to query params
    order_id = session.delete(:wallet_deposit_order_id).presence || params[:orderId].to_s
    amount   = session.delete(:wallet_deposit_amount).to_f

    if order_id.blank?
      redirect_to wallet_path, alert: "Sesyon depo pa valid."
      return
    end

    verified = MoncashService.verify_order(order_id)

    unless verified
      redirect_to wallet_path, alert: "Nou pa t kapab verifye depo a ak MonCash. Tanpri kontakte sipò."
      return
    end

    # If amount was lost from session (e.g. double-submit), retrieve from MonCash
    if amount <= 0
      amount = retrieve_moncash_payment_amount(order_id)
    end

    if amount <= 0
      redirect_to wallet_path, alert: "Depo verifye men montan pa valid. Tanpri kontakte sipò."
      return
    end

    begin
      WalletService.new(@wallet).deposit!(
        amount: amount,
        moncash_transaction_id: order_id
      )
      redirect_to wallet_path, notice: "Depo #{amount.to_i} HTG reyisi! Balans ou ajou."
    rescue WalletService::DuplicateDepositError
      redirect_to wallet_path, notice: "Depo sa a deja trete."
    end
  end

  # ── POST /wallet/withdraw ──
  def withdraw
    amount  = params[:amount].to_f
    phone   = params[:moncash_phone].to_s.strip
    instant = params[:instant] == "1"

    if amount < WITHDRAW_MIN || amount > WITHDRAW_MAX
      redirect_to wallet_path, alert: "Montan retrè dwe ant #{WITHDRAW_MIN} ak #{number_with_delimiter(WITHDRAW_MAX)} HTG."
      return
    end

    unless phone.match?(/\A509\d{8}\z/)
      redirect_to wallet_path, alert: "Tanpri antre yon nimewo MonCash valid (509 + 8 chif)."
      return
    end

    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to wallet_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

    fee = instant ? WalletService.calculate_instant_fee(amount) : 0

    begin
      WalletService.new(@wallet).withdraw!(amount: amount, instant: instant)

      if instant
        WalletWithdrawWorker.perform_async(current_user.id, amount, phone, fee.to_f)
        redirect_to wallet_path, notice: "Retrè instant #{amount.to_i} HTG an kou (frè: #{fee.to_i} HTG). Lajan ap rive nan MonCash ou nan kèk segonn."
      else
        WalletWithdrawWorker.perform_in(48.hours, current_user.id, amount, phone, 0)
        redirect_to wallet_path, notice: "Retrè #{amount.to_i} HTG pwograme. Lajan ap rive nan MonCash ou nan 48 èdtan."
      end
    rescue WalletService::InsufficientFundsError
      if instant && fee > 0
        redirect_to wallet_path, alert: "Balans pa sifi. Ou bezwen #{amount.to_i} HTG + #{fee.to_i} HTG frè instant = #{(amount + fee).to_i} HTG."
      else
        redirect_to wallet_path, alert: "Balans pa sifi pou retrè sa a."
      end
    rescue WalletService::FrozenAccountError
      redirect_to wallet_path, alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
    end
  end

  private

  def load_wallet
    @wallet = current_user.ensure_wallet!
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
      Rails.logger.error "MonCash Wallet Deposit Failed: #{response.status} #{response.body}"
      nil
    end
  rescue => e
    Rails.logger.error "MonCash Wallet Deposit Error: #{e.message}"
    nil
  end

  # Retrieve payment amount from MonCash when session data is lost (double-submit edge case)
  def retrieve_moncash_payment_amount(order_id)
    token = MoncashService.get_token
    return 0 unless token

    conn = Faraday.new(url: "#{MoncashService::BASE_URL}/Api/v1/RetrieveOrderPayment")
    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Content-Type']  = 'application/json'
      req.body = { orderId: order_id.to_s }.to_json
    end

    if response.success?
      data = JSON.parse(response.body)
      data.dig("payment", "cost").to_f
    else
      0
    end
  rescue => e
    Rails.logger.error "MonCash retrieve amount error: #{e.message}"
    0
  end
end

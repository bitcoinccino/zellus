class WalletsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_wallet

  DEPOSIT_MIN  = 131
  DEPOSIT_MAX  = 327_678
  WITHDRAW_MIN = 100
  WITHDRAW_MAX = 50_000
  USDC_WITHDRAW_MIN = BigDecimal("1")
  USDC_WITHDRAW_MAX = BigDecimal("500")

  # ── GET /wallet ──
  def show
    @ledger_entries = @wallet.wallet_ledger_entries.recent_first.includes(:reference).limit(25)
    @moncash_methods = current_user.payment_methods.active.mobile_wallet.moncash.order(created_at: :desc)
    @bank_methods = current_user.payment_methods.active.bank_account.where(provider: :unibank).order(created_at: :desc)
    @treasury_address = CryptoKeyHelper.treasury_address
    @incoming_requests = PaymentRequest.incoming_for(current_user).includes(:user).recent_first
    @sell_rate = RateService.sell_rate  # USD→HTG: user gets this many HTG per USD
    @buy_rate  = RateService.buy_rate   # HTG→USD: user pays this many HTG per USD
    @limit_service = WalletLimitService.new(current_user)
    @business = current_user.business
    # ETH/BTC/stock rates disabled (HTG + USD only mode)
    @btc_usd_rate = 0
    @eth_usd_rate = 0
    @stock_usd_rates = %w[tslax nvdax aaplx coinx googlx].index_with { |_| 0 }
  end

  # ── POST /wallet/deposit ──
  def deposit
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to wallet_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

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
      NotificationService.deposit_confirmed(current_user, amount)
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

    fee = instant ? WalletService.calculate_instant_fee(amount) : WalletService.calculate_standard_fee(amount)
    payout = amount - fee  # What user actually receives

    begin
      WalletService.new(@wallet).withdraw!(amount: amount, instant: instant)

      if instant
        WalletWithdrawWorker.perform_async(current_user.id, amount, phone, fee.to_f)
        redirect_to wallet_path, notice: "Retrè instant #{payout.to_i} HTG an kou (frè: #{fee.to_i} HTG). Lajan ap rive nan MonCash ou nan kèk segonn."
      else
        WalletWithdrawWorker.perform_in(48.hours, current_user.id, amount, phone, fee.to_f)
        redirect_to wallet_path, notice: "Retrè #{payout.to_i} HTG pwograme (frè: #{fee.to_i} HTG). Lajan ap rive nan MonCash ou nan 48 èdtan."
      end

      # Email confirmation
      begin
        WalletMailer.with(user_id: current_user.id, amount: amount.to_f, asset: "htg", phone: phone, instant: instant, fee: fee.to_f)
                    .withdrawal_queued.deliver_later
      rescue => e
        Rails.logger.error "Wallet withdrawal_queued email failed: #{e.message}"
      end
    rescue WalletService::InsufficientFundsError
      redirect_to wallet_path, alert: "Balans pa sifi. Ou bezwen #{amount.to_i} HTG pou retrè sa a."
    rescue WalletService::FrozenAccountError
      redirect_to wallet_path, alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
    end
  end

  # ── POST /wallet/withdraw_usdc ──
  def withdraw_usdc
    redirect_to wallet_path, alert: "Retrè kripto dezaktive pou kounye a. Ou ka konvèti USD an Goud epi retire via MonCash."
    return
    # --- Disabled: deposit-only crypto model ---
    amount     = BigDecimal(params[:amount].to_s)
    to_address = params[:wallet_address].to_s.strip

    if amount < USDC_WITHDRAW_MIN || amount > USDC_WITHDRAW_MAX
      redirect_to wallet_path, alert: "Montan retrè USD dwe ant #{USDC_WITHDRAW_MIN} ak #{USDC_WITHDRAW_MAX} USD."
      return
    end

    unless to_address.match?(/\A0x[0-9a-fA-F]{40}\z/)
      redirect_to wallet_path, alert: "Tanpri antre yon adrès Base valid (0x…)."
      return
    end

    # Block withdrawals to treasury address (self-transfer)
    if to_address.downcase == CryptoKeyHelper.treasury_address.downcase
      redirect_to wallet_path, alert: "Ou pa ka retire nan adrès trezori a."
      return
    end

    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to wallet_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

    begin
      WalletService.new(@wallet).withdraw!(amount: amount, asset: "usdc")
      WalletUsdcWithdrawWorker.perform_async(current_user.id, amount.to_f, to_address)
      redirect_to wallet_path, notice: "Retrè #{amount} USD an kou. Tranzaksyon ap trete sou Base."
    rescue WalletService::InsufficientFundsError
      redirect_to wallet_path, alert: "Balans USD pa sifi pou retrè sa a."
    rescue WalletService::FrozenAccountError
      redirect_to wallet_path, alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
    end
  end

  # ── POST /wallet/withdraw_stock ──
  def withdraw_stock
    redirect_to wallet_path, alert: "Retrè stòk dezaktive pou kounye a. Fonksyon sa a ap retounen byento."
    return
    # --- Disabled: deposit-only crypto model ---
    ticker     = params[:ticker].to_s.strip.downcase
    amount     = BigDecimal(params[:amount].to_s)
    to_address = params[:wallet_address].to_s.strip

    valid_tickers = %w[tslax nvdax aaplx coinx googlx]
    unless valid_tickers.include?(ticker)
      redirect_to wallet_path, alert: "Stòk sa a pa valid."
      return
    end

    if amount <= 0
      redirect_to wallet_path, alert: "Montan retrè dwe plis pase 0."
      return
    end

    unless to_address.match?(/\A0x[0-9a-fA-F]{40}\z/)
      redirect_to wallet_path, alert: "Tanpri antre yon adrès Base valid (0x…)."
      return
    end

    if to_address.downcase == CryptoKeyHelper.treasury_address.downcase
      redirect_to wallet_path, alert: "Ou pa ka retire nan adrès trezori a."
      return
    end

    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to wallet_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

    begin
      WalletService.new(@wallet).withdraw!(amount: amount, asset: ticker)
      NotificationService.withdrawal_sent(current_user, amount, ticker.upcase)
      redirect_to wallet_path, notice: "Retrè #{amount} #{ticker.upcase} an kou. Tranzaksyon ap trete sou Base."
    rescue WalletService::InsufficientFundsError
      redirect_to wallet_path, alert: "Balans #{ticker.upcase} pa sifi pou retrè sa a."
    rescue WalletService::FrozenAccountError
      redirect_to wallet_path, alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
    end
  end

  # ── POST /wallet/withdraw_bank ──
  def withdraw_bank
    amount       = params[:amount].to_f
    account_num  = params[:bank_account_number].to_s.strip
    holder_name  = params[:account_holder_name].to_s.strip
    bank_name    = "UNIBANK"

    if amount < BankWithdrawal::MIN_AMOUNT || amount > BankWithdrawal::MAX_AMOUNT
      redirect_to wallet_path, alert: "Montan retrè bank dwe ant #{BankWithdrawal::MIN_AMOUNT} ak #{number_with_delimiter(BankWithdrawal::MAX_AMOUNT)} HTG."
      return
    end

    if account_num.blank?
      redirect_to wallet_path, alert: "Tanpri antre nimewo kont bank ou."
      return
    end

    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to wallet_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

    fee = WalletService.calculate_bank_fee(amount)
    payout = amount - fee

    begin
      entry = WalletService.new(@wallet).withdraw_bank!(
        amount: amount, fee: fee
      )

      bank_withdrawal = BankWithdrawal.create!(
        user: current_user,
        wallet: @wallet,
        wallet_ledger_entry: entry,
        amount: amount,
        bank_name: bank_name,
        bank_account_number: account_num,
        account_holder_name: holder_name.presence
      )

      # Send notification email
      begin
        WalletMailer.with(
          user_id: current_user.id, amount: amount.to_f, asset: "htg",
          bank_name: bank_name, bank_account: account_num,
          account_holder: holder_name.presence, fee: fee.to_f
        ).bank_withdrawal_queued.deliver_later
      rescue => e
        Rails.logger.error "Bank withdrawal_queued email failed: #{e.message}"
      end

      NotificationService.withdrawal_sent(current_user, payout, "UniBank")
      redirect_to wallet_path, notice: "Retrè bank #{payout.to_i} HTG an kou (frè: #{fee.to_i} HTG). Trete nan 1-2 jou ouvrab."
    rescue WalletService::InsufficientFundsError
      redirect_to wallet_path, alert: "Balans pa sifi. Ou bezwen #{amount.to_i} HTG pou retrè sa a."
    rescue WalletService::FrozenAccountError
      redirect_to wallet_path, alert: "Pòtfèy ou jele. Tanpri kontakte sipò."
    end
  end

  # ── GET /wallet/rates (Mache Dechanj) ──
  # ── GET /wallet/test_sound — test real-time notification sound + balance ──
  def test_sound
    Rails.logger.info "[Zèllus] test_sound triggered for user #{current_user.id}"

    # 1. Sound notification
    NotificationChannel.broadcast_to(
      current_user,
      { title: "Test notification", type: "transfer_received", play_sound: true }
    )

    # 2. Balance update (sends current real balances)
    wallet = current_user.wallet
    if wallet
      NotificationChannel.broadcast_to(
        current_user,
        {
          type: "balance_update",
          balances: {
            htg:  wallet.htg_balance.to_f.round(2),
            usdc: wallet.usdc_balance.to_f.round(2),
            eth:  wallet.eth_balance.to_f.round(6),
            wbtc: wallet.wbtc_balance.to_f.round(8)
          },
          asset_changed: "test"
        }
      )
    end

    Rails.logger.info "[Zèllus] test_sound + balance broadcast sent"
    render plain: "Sound + balance broadcast sent to user #{current_user.id} (#{current_user.display_name})."
  end

  # ── GET /wallet/balances.json — AJAX balance refresh ──
  def balances
    wallet = current_user.wallet
    if wallet
      render json: {
        htg:  wallet.htg_balance.to_f.round(2),
        usdc: wallet.usdc_balance.to_f.round(2),
        eth:  wallet.eth_balance.to_f.round(6),
        wbtc: wallet.wbtc_balance.to_f.round(8)
      }
    else
      render json: { htg: 0, usdc: 0, eth: 0, wbtc: 0 }
    end
  end

  def rates
    @sell_rate      = RateService.sell_rate
    @buy_rate       = RateService.buy_rate
    # ETH/BTC/stock rates disabled (HTG + USD only mode)
    @btc_usd_rate = 0
    @eth_usd_rate = 0
    @stock_usd_rates = %w[tslax nvdax aaplx coinx googlx].index_with { |_| 0 }

    # Market data — USD/HTG only
    @market_data = {}
    %w[usdc].each do |key|
      @market_data[key] = RateService.market_data(key)
    end
  end

  # ── GET /wallet/entries/:token ──
  def show_entry
    @entry = @wallet.wallet_ledger_entries.find_by!(token: params[:token])
    @btc_usd_rate = RateService.btc_usd_rate rescue 95_000.0
    @eth_usd_rate = RateService.eth_usd_rate rescue 3_500.0
  end

  # ── POST /wallet/convert ──
  def convert
    from_asset = params[:from_asset].to_s.downcase.strip
    to_asset   = params[:to_asset].to_s.downcase.strip
    amount     = BigDecimal(params[:amount].to_s)

    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to wallet_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

    valid_assets = %w[htg usdc]
    unless valid_assets.include?(from_asset) && valid_assets.include?(to_asset) && from_asset != to_asset
      redirect_to wallet_path, alert: "Konvèsyon pa valid."
      return
    end

    # Daily swap limit check (USD→HTG only)
    if from_asset == "usdc" && to_asset == "htg"
      limit_svc = WalletLimitService.new(current_user)
      unless limit_svc.swap_allowed?(amount)
        remaining = limit_svc.daily_swap_remaining
        redirect_to wallet_path, alert: "Ou rive nan limit konvèsyon jounalye ou (#{limit_svc.limits[:daily_swap_usd].to_i} USD/jou). Ou ka konvèti #{remaining.to_f.round(2)} USD ankò jodi a."
        return
      end
    end

    result = WalletService.new(@wallet).convert!(
      amount: amount, from_asset: from_asset, to_asset: to_asset
    )

    from_label = from_asset == "usdc" ? "USD" : from_asset.upcase
    to_label   = to_asset == "usdc" ? "USD" : to_asset.upcase
    fee_note = result[:fee] && result[:fee] > 0 ? " (frè: #{result[:fee]} #{to_label})" : ""
    NotificationService.conversion_completed(current_user, result[:from], from_asset, result[:to], to_asset)
    redirect_to wallet_path,
      notice: "Konvèti #{result[:from]} #{from_label} → #{result[:to]} #{to_label} reyisi!#{fee_note}"

  rescue WalletService::InsufficientFundsError => e
    redirect_to wallet_path, alert: e.message
  rescue WalletService::InvalidAmountError => e
    redirect_to wallet_path, alert: e.message
  rescue => e
    Rails.logger.error "Wallet convert error: #{e.message}"
    redirect_to wallet_path, alert: "Erè nan konvèsyon. Tanpri eseye ankò."
  end

  # ── POST /wallet/withdraw_eth (disabled) ──
  def withdraw_eth
    redirect_to wallet_path, alert: "Retrè kripto dezaktive pou kounye a. Ou ka konvèti an Goud epi retire via MonCash."
  end

  # ── POST /wallet/withdraw_wbtc (disabled) ──
  def withdraw_wbtc
    redirect_to wallet_path, alert: "Retrè kripto dezaktive pou kounye a. Ou ka konvèti an Goud epi retire via MonCash."
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

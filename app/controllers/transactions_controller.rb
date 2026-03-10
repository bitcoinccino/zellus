class TransactionsController < ApplicationController
  before_action :authenticate_user!

  # 1. Dashboard: See past transfers
  def index
    @transactions = current_user.transactions.order(created_at: :desc)
  end
  # 2. Start: Input amount and Base wallet
  def new
    @transaction = current_user.transactions.new
    load_order_limits
    load_display_rates
    apply_request_prefill
    load_buy_payment_methods
    load_sell_payment_methods
  end

  # 3. Save: Create pending record and go to Review
  def create
    load_order_limits
    load_display_rates
    load_buy_payment_methods
    load_sell_payment_methods
    tx_type          = params[:transaction_type] == "sell" ? "sell" : "buy"

    # PIN verification
    unless current_user.transfer_pin_set?
      flash.now[:alert] = "Ou dwe kreye yon PIN transfè anvan ou ka kontinye."
      @initial_exchange_tab = tx_type
      render :new, status: :unprocessable_entity
      return
    end

    unless current_user.verify_transfer_pin(params[:transfer_pin])
      flash.now[:alert] = "PIN pa kòrèk. Tanpri eseye ankò."
      @initial_exchange_tab = tx_type
      render :new, status: :unprocessable_entity
      return
    end
    # HTG + USD only mode: force all transactions to USDC
    @sell_crypto     = "usdc"
    @buy_crypto      = "usdc"
    # Block non-USD assets
    requested_buy  = params[:crypto_currency].to_s
    requested_sell = params[:sell_crypto_currency].to_s
    if %w[wbtc eth tslax nvdax aaplx coinx googlx].include?(requested_buy) || %w[wbtc].include?(requested_sell)
      redirect_to new_transaction_path, alert: "Sèlman USD disponib pou kounye a. ETH, wBTC, ak stòk ap vini byento."
      return
    end
    @exchange_rate   = if tx_type == "sell"
                         @sell_crypto == "wbtc" ? @wbtc_htg_sell_rate : @sell_exchange_rate
                       else
                         case @buy_crypto
                         when "wbtc" then @wbtc_htg_buy_rate
                         when "eth"  then @eth_htg_buy_rate
                         when "tslax", "nvdax", "aaplx", "coinx", "googlx"
                           @stock_rates[@buy_crypto][:htg_buy]
                         else @buy_exchange_rate
                         end
                       end

    if tx_type == "sell"
      selected_payment_method = current_user.payment_methods.active.mobile_wallet.moncash.find_by(id: params[:payment_method_id])
      payout_moncash_phone    = selected_payment_method&.account_number.presence || params[:moncash_phone].to_s.strip

      # Sell flow: user specifies crypto amount, we calculate HTG payout
      crypto_amount      = params[:crypto_amount_sell].to_f
      sell_currency_sym  = @sell_crypto == "wbtc" ? :wbtc : :usdc
      if sell_amount_limit_error(crypto_amount, @sell_crypto).present?
        flash.now[:alert] = sell_amount_limit_error(crypto_amount, @sell_crypto)
        @initial_exchange_tab = "sell"
        @prefill_crypto_amount_sell = params[:crypto_amount_sell]
        @prefill_moncash_phone = payout_moncash_phone
        @prefill_sell_crypto = @sell_crypto
        load_buy_payment_methods
        load_sell_payment_methods
        render :new, status: :unprocessable_entity
        return
      end
      gross_htg          = (crypto_amount * @exchange_rate).round(2)
      fee_htg            = FeeService.crypto_fee(gross_htg)
      net_htg            = gross_htg - fee_htg
      @fee_percentage    = FeeService.crypto_fee_percent(gross_htg)

      @transaction = current_user.transactions.new(
        transaction_type:    :sell,
        crypto_currency:     sell_currency_sym,
        crypto_amount:       crypto_amount,
        fiat_amount:         net_htg,
        fee_amount:          fee_htg,
        exchange_rate:       @exchange_rate,
        moncash_phone:       payout_moncash_phone,
        destination_address: ENV['TREASURY_ADDRESS'] || "0x9BAC1AC641d7c08caE0f524cC62a81C6abe73dEa",
        status:              :pending
      )
      apply_request_receiver_override!(@transaction, tx_type: "sell")

      preflight_error = sell_payout_preflight_error(@transaction.moncash_phone)
      if preflight_error.present?
        flash.now[:alert] = preflight_error
        @initial_exchange_tab = "sell"
        @prefill_crypto_amount_sell = params[:crypto_amount_sell]
        @prefill_moncash_phone = @transaction.moncash_phone
        load_buy_payment_methods
        load_sell_payment_methods
        render :new, status: :unprocessable_entity
        return
      end
    else
      selected_crypto_method = current_user.payment_methods.active.crypto_wallet.find_by(id: params[:crypto_payment_method_id])
      buy_destination_address = selected_crypto_method&.wallet_address.presence || params[:destination_address]

      # Buy flow: user specifies HTG amount, we calculate crypto to send
      @transaction = current_user.transactions.new(transaction_params)
      @transaction.transaction_type = :buy
      @transaction.crypto_currency  = @buy_crypto.to_sym
      @transaction.destination_address = buy_destination_address.to_s.strip
      if buy_amount_limit_error(@transaction.fiat_amount).present?
        flash.now[:alert] = buy_amount_limit_error(@transaction.fiat_amount)
        @initial_exchange_tab = "buy"
        @prefill_fiat_amount = params[:fiat_amount]
        @prefill_destination_address = buy_destination_address.to_s.strip
        load_buy_payment_methods
        load_sell_payment_methods
        render :new, status: :unprocessable_entity
        return
      end
      @transaction.fee_amount       = FeeService.crypto_fee(@transaction.fiat_amount)
      @fee_percentage               = FeeService.crypto_fee_percent(@transaction.fiat_amount)
      net_fiat                      = @transaction.fiat_amount - @transaction.fee_amount
      precision = case @buy_crypto
                  when "wbtc", "eth" then 8
                  when "tslax", "nvdax", "aaplx", "coinx", "googlx" then 8
                  else 6
                  end
      @transaction.crypto_amount    = (net_fiat / @exchange_rate).round(precision)
      @transaction.status           = :pending
      @transaction.exchange_rate    = @exchange_rate
      apply_request_receiver_override!(@transaction, tx_type: "buy")
    end

    if @transaction.save
      begin
        TransactionMailer.with(transaction_id: @transaction.id).created.deliver_later
      rescue => e
        Rails.logger.error "Transaction created email failed [tx=#{@transaction.id}]: #{e.message}"
      end
      redirect_to transaction_path(@transaction)
    else
      load_display_rates
      load_order_limits
      load_buy_payment_methods
      load_sell_payment_methods
      render :new, status: :unprocessable_entity
    end
  end



  # 4. Review: The "Confirm" page we just built
  def show
    @transaction = current_user.transactions.find_by!(token: params[:ref])
  end

  # 5. Execute: Trigger the MonCash API
  def pay
    @transaction = current_user.transactions.find_by!(token: params[:ref])
    
    # MoncashService.create_payment now updates @transaction.last_moncash_order_id internally
    url = MoncashService.create_payment(@transaction)
    
    if url
      # Use allow_other_host: true for external redirects in Rails 7+
      redirect_to url, allow_other_host: true
    else
      flash[:error] = "Payment gateway unavailable. Check your MonCash Sandbox account status."
      redirect_to transaction_path(@transaction)
    end
  end

  # 5b. Dev/admin fallback: mark buy payment as paid without MonCash callback/OTP
  def manual_confirm
    @transaction = current_user.transactions.find_by!(token: params[:ref])

    unless manual_confirm_allowed?
      redirect_to transaction_path(@transaction), alert: "Manual confirmation is disabled."
      return
    end

    unless @transaction.buy? && @transaction.pending?
      redirect_to transaction_path(@transaction), alert: "Only pending buy transactions can be manually confirmed."
      return
    end

    @transaction.paid!
    CryptoTransferWorker.perform_async(@transaction.id)
    redirect_to transaction_path(@transaction), notice: "Manual payment confirmation applied. Sending crypto..."
  end

  # 5c. Sell flow: user submits the Base tx hash proving they sent USDC to treasury
  def submit_sell_tx_hash
    @transaction = current_user.transactions.find_by!(token: params[:ref])

    unless @transaction.sell?
      redirect_to transaction_path(@transaction), alert: "TX hash submission is only available for sell orders."
      return
    end

    unless @transaction.pending? || @transaction.failed?
      redirect_to transaction_path(@transaction), alert: "This sell order can no longer accept a new deposit TX hash."
      return
    end

    tx_hash = params[:sell_deposit_tx_hash].to_s.strip
    unless tx_hash.match?(/\A0x[a-fA-F0-9]{64}\z/)
      redirect_to transaction_path(@transaction), alert: "Enter a valid Base transaction hash (0x + 64 hex chars)."
      return
    end

    @transaction.update!(
      blockchain_tx_hash: tx_hash,
      status: :crypto_sent,
      failure_reason: nil
    )
    SellTransferWorker.perform_async(@transaction.id)

    crypto_label = @transaction.wbtc? ? "WBTC" : "USD"
    redirect_to transaction_path(@transaction), notice: "Deposit TX hash submitted. We are verifying your #{crypto_label} transfer on Base."
  end

  # 6. Success: Land here after paying on the Digicel site
 def success
  @moncash_id  = params[:transactionId]
  @order_id    = params[:orderId]

  # ── Wallet deposit redirect ──
  # MonCash uses one return URL for all payments. Detect wallet deposits
  # by order_id prefix and route to the wallet deposit handler.
  if @order_id.to_s.start_with?("wallet-deposit-")
    redirect_to deposit_success_wallet_path(transactionId: @moncash_id, orderId: @order_id)
    return
  end

  # Find the transaction
  @transaction = Transaction.find_by(last_moncash_order_id: @order_id) ||
                 Transaction.find_by(moncash_transaction_id: @moncash_id) ||
                 current_user.transactions.last

  if @transaction.nil?
    redirect_to transactions_path, alert: "Transaction not found."
    return
  end

  # --- NEW: ZÈLLUS LOAN REPAYMENT LOGIC ---
  if @transaction.loan_request? || @transaction.failure_reason&.include?("REPAYMENT_LOAN_")
    # Check if they used USDC (Sovereign Bonus) or HTG
    is_usdc = @transaction.failure_reason&.include?("USDC") || @transaction.sell?
    flash[:repayment_points] = is_usdc ? 60 : 50
    flash[:show_rank_modal] = true
  end
  # ------------------------------------------

  if @transaction.paid? || @transaction.crypto_sent? || @transaction.completed?
    flash.now[:notice] = "Mèsi! Payment already confirmed."
  else
    # Standard verification logic
    verified = MoncashService.verify_order(@transaction.last_moncash_order_id)

    if verified
      @transaction.paid!
      # Only send USDC if it's a regular BUY, not a loan repayment
      unless @transaction.failure_reason&.include?("REPAYMENT_LOAN_")
        CryptoTransferWorker.perform_async(@transaction.id)
      end
      flash.now[:notice] = "Mèsi! Payment confirmed."
    else
      flash.now[:alert] = "We couldn't verify your payment with MonCash."
    end
  end
end

  
  private

  def load_display_rates
    @buy_exchange_rate  = RateService.buy_rate
    @sell_exchange_rate = RateService.sell_rate
    # ETH/BTC/stock rates disabled (HTG + USD only mode)
    @wbtc_htg_buy_rate  = 0
    @wbtc_htg_sell_rate = 0
    @eth_htg_buy_rate   = 0
    @eth_htg_sell_rate  = 0
    @stock_rates = %w[tslax nvdax aaplx coinx googlx].index_with { |_| { usd: 0, htg_buy: 0, htg_sell: 0 } }
    @rates_updated_at   = RateService.usd_htg_rate_updated_at
  rescue => e
    Rails.logger.error "TransactionsController rate load failed: #{e.message}"
    @buy_exchange_rate = @sell_exchange_rate = 135.50
    @wbtc_htg_buy_rate = @wbtc_htg_sell_rate = 12_872_500.0
    @eth_htg_buy_rate = @eth_htg_sell_rate = 390_000.0
    @stock_rates = %w[tslax nvdax aaplx coinx googlx].index_with { |_| { usd: 0, htg_buy: 0, htg_sell: 0 } }
    @rates_updated_at = nil
  end

  def load_order_limits
    @buy_min_htg   = ENV.fetch("BUY_MIN_HTG", "100").to_f
    @buy_max_htg   = ENV.fetch("BUY_MAX_HTG", "100000").to_f
    @sell_min_usdc = ENV.fetch("SELL_MIN_USDC", "1").to_f
    @sell_max_usdc = ENV.fetch("SELL_MAX_USDC", "1000").to_f
    @sell_min_wbtc = ENV.fetch("SELL_MIN_WBTC", "0.0001").to_f
    @sell_max_wbtc = ENV.fetch("SELL_MAX_WBTC", "1").to_f
    @sell_min_eth  = ENV.fetch("SELL_MIN_ETH", "0.005").to_f
    @sell_max_eth  = ENV.fetch("SELL_MAX_ETH", "10").to_f
  rescue => e
    Rails.logger.error "TransactionsController limit load failed: #{e.message}"
    @buy_min_htg, @buy_max_htg = 100.0, 100_000.0
    @sell_min_usdc, @sell_max_usdc = 1.0, 1000.0
    @sell_min_wbtc, @sell_max_wbtc = 0.0001, 1.0
    @sell_min_eth, @sell_max_eth = 0.005, 10.0
  end

  def load_sell_payment_methods
    @sell_payment_methods = current_user.payment_methods.active.mobile_wallet.moncash.order(created_at: :desc)
  end

  def load_buy_payment_methods
    @buy_wallet_methods = current_user.payment_methods.active.crypto_wallet.base.order(created_at: :desc)
    @buy_moncash_methods = current_user.payment_methods.active.mobile_wallet.moncash.order(created_at: :desc)
  end

  def manual_confirm_allowed?
    Rails.env.development? || current_user.email == ENV['ADMIN_EMAIL'].to_s.strip
  end

  def transaction_params
    # Forms submit top-level fields (plus Rails metadata like authenticity_token/button).
    # Slice only the fields we persist to avoid noisy unpermitted-parameter logs.
    params.to_unsafe_h.slice("fiat_amount", "destination_address", "crypto_currency", "transaction_type", "moncash_phone")
  end

  def apply_request_prefill
    @initial_exchange_tab = params[:prefill_tab].to_s == "sell" ? "sell" : "buy"
    @request_prefill_context = find_request_prefill_context
    return unless @request_prefill_context

    request = @request_prefill_context
    @initial_exchange_tab = request.htg? ? "sell" : "buy"

    fee_multiplier = BigDecimal("0.98")
    if request.htg?
      rate = BigDecimal(@sell_exchange_rate.to_s)
      required_usdc = (BigDecimal(request.amount.to_s) / (rate * fee_multiplier)).round(6)
      @prefill_crypto_amount_sell = required_usdc.to_s("F")
      @prefill_moncash_phone = request.receiver_account_number if request.receiver_account_number.present?
    else
      rate = BigDecimal(@buy_exchange_rate.to_s)
      required_htg = (BigDecimal(request.amount.to_s) * rate / fee_multiplier).round(2)
      @prefill_fiat_amount = required_htg.to_s("F")
      @prefill_destination_address = request.receiver_wallet_address if request.receiver_wallet_address.present?
    end
  rescue ArgumentError, TypeError
    @initial_exchange_tab = "buy"
  end

  def find_request_prefill_context
    token = params[:request_token].to_s.strip
    return nil if token.blank?

    request = PaymentRequest.find_by(token: token)
    return nil unless request

    request.mark_expired_if_needed!
    return nil unless request.active?

    request
  rescue => e
    Rails.logger.error "TransactionsController request prefill failed: #{e.message}"
    nil
  end

  def apply_request_receiver_override!(transaction, tx_type:)
    request = find_request_prefill_context
    return unless request

    if tx_type == "sell" && request.receiver_account_number.present?
      transaction.moncash_phone = request.receiver_account_number
    elsif tx_type == "buy" && request.receiver_wallet_address.present?
      transaction.destination_address = request.receiver_wallet_address
    end
  end

  def sell_payout_preflight_error(moncash_phone)
    phone = moncash_phone.to_s.strip
    return "Enter a valid MonCash number before creating a sell order." if phone.blank?

    prefunded = MoncashService.prefunded_balance_info
    unless prefunded[:success]
      return "MonCash payout is temporarily unavailable right now. Please try again later."
    end

    customer = MoncashService.customer_status(phone)
    unless customer[:success]
      raw_error = customer[:error].to_s
      return "MonCash payout is temporarily unavailable right now. Please try again later." if raw_error.match?(/short code|prefunded|MFS can't process/i)

      return "We could not validate that MonCash number right now. Please verify the number and try again."
    end

    return nil if customer[:active]

    "The destination MonCash number is not active. Please use another MonCash number."
  rescue => e
    Rails.logger.error "Sell payout preflight failed: #{e.message}"
    "MonCash payout is temporarily unavailable right now. Please try again later."
  end

  def buy_amount_limit_error(amount)
    value = amount.to_f
    return "Enter a valid HTG amount." if value <= 0
    return "Minimum buy amount is #{format_limit(@buy_min_htg)} HTG." if value < @buy_min_htg
    return "Maximum buy amount is #{format_limit(@buy_max_htg)} HTG." if value > @buy_max_htg

    nil
  end

  def sell_amount_limit_error(amount, crypto = "usdc")
    value = amount.to_f
    if crypto == "wbtc"
      label = "WBTC"
      min = @sell_min_wbtc
      max = @sell_max_wbtc
      prec = 8
    elsif crypto == "eth"
      label = "ETH"
      min = @sell_min_eth
      max = @sell_max_eth
      prec = 6
    else
      label = "USD"
      min = @sell_min_usdc
      max = @sell_max_usdc
      prec = 2
    end
    return "Enter a valid #{label} amount." if value <= 0
    return "Minimum sell amount is #{format_limit(min, precision: prec)} #{label}." if value < min
    return "Maximum sell amount is #{format_limit(max, precision: prec)} #{label}." if value > max

    nil
  end

  def format_limit(value, precision: 0)
    rounded = precision.zero? ? value.to_i : value.round(precision)
    precision.zero? ? rounded.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse : rounded.to_s
  end
end

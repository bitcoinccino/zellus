require "faraday"
require "openssl"
require "digest/keccak"

class Admin::DashboardController < Admin::BaseController
  include ActionView::Helpers::NumberHelper

  def index
    # 1. Financial Overviews
    active_statuses      = [ :paid, :crypto_sent, :completed ]
    active_txs           = Transaction.where(status: active_statuses)

    @total_fees          = active_txs.sum(:fee_amount)
    @total_volume        = active_txs.sum(:fiat_amount)
    @tx_processed        = Transaction.where(status: :completed).count
    @recent_transactions = Transaction.includes(user: [ :business, { avatar_attachment: :blob } ]).order(created_at: :desc).limit(15)

    # Per-type profit breakdown (Achte / Vann / Prè)
    @buy_fees   = active_txs.where(transaction_type: :buy).sum(:fee_amount)
    @sell_fees  = active_txs.where(transaction_type: :sell).sum(:fee_amount)
    @loan_fees  = active_txs.where(transaction_type: :loan_request).sum(:fee_amount)

    # Per-type tx counts
    @buy_count  = active_txs.where(transaction_type: :buy).count
    @sell_count = active_txs.where(transaction_type: :sell).count
    @loan_count = active_txs.where(transaction_type: :loan_request).count

    # Wallet ledger fees (conversion, withdrawal, transfer fees)
    ledger_fee_types = %w[fee instant_fee conversion_fee]
    ledger_fees = WalletLedgerEntry.where(entry_type: ledger_fee_types)

    @conversion_fees_htg = ledger_fees.where(entry_type: "conversion_fee", asset: "htg").sum(:amount)
    @conversion_fees_usd = ledger_fees.where(entry_type: "conversion_fee", asset: "usd").sum(:amount)
    @conversion_fee_count = ledger_fees.where(entry_type: "conversion_fee").count

    @withdraw_fees_htg = ledger_fees.where(entry_type: %w[fee instant_fee], asset: "htg").sum(:amount)
    @withdraw_fees_usd = ledger_fees.where(entry_type: %w[fee instant_fee], asset: "usd").sum(:amount)
    @withdraw_fee_count = ledger_fees.where(entry_type: %w[fee instant_fee]).count

    # USD equivalents using live rate
    @usd_htg_rate      = begin; RateService.usd_htg_rate; rescue; 135.50; end

    # Combine all fees: Transaction fees (HTG) + ledger fees (HTG + USD→HTG)
    @ledger_fees_as_htg = (@conversion_fees_htg + @withdraw_fees_htg) +
                          ((@conversion_fees_usd + @withdraw_fees_usd) * @usd_htg_rate)
    @grand_total_fees   = @total_fees + @ledger_fees_as_htg

    @total_fees_usd    = @usd_htg_rate > 0 ? (@total_fees / @usd_htg_rate).round(2) : 0
    @total_volume_usd  = @usd_htg_rate > 0 ? (@total_volume / @usd_htg_rate).round(2) : 0
    @buy_fees_usd      = @usd_htg_rate > 0 ? (@buy_fees / @usd_htg_rate).round(2) : 0
    @sell_fees_usd     = @usd_htg_rate > 0 ? (@sell_fees / @usd_htg_rate).round(2) : 0
    @loan_fees_usd     = @usd_htg_rate > 0 ? (@loan_fees / @usd_htg_rate).round(2) : 0
    @grand_total_fees_usd = @usd_htg_rate > 0 ? (@grand_total_fees / @usd_htg_rate).round(2) : 0

    # 2. Aksyon an Atant (Agents + Bank Withdrawals only — Prè moved to Bousad)
    @pending_bank_withdrawals = BankWithdrawal.includes(:user)
                                              .where(status: %w[pending processing])
                                              .order(created_at: :asc)

    @pending_agent_applications = Business.includes(:user)
                                          .agent_pending
                                          .order(agent_applied_at: :asc)

    # Pending loans count (for badge display)
    @pending_loans_count = Transaction.where(transaction_type: :loan_request, status: :pending).count

    # All Businesses (for agent management)
    @all_businesses = Business.includes(:user).order(created_at: :desc)

    # User count
    @user_count = User.count

    # 3. Live Ticker — last 5 events across all types
    ticker_items = []
    Transaction.includes(user: { avatar_attachment: :blob }).order(created_at: :desc).limit(5).each do |tx|
      ticker_items << Admin::ActivityItem.from_transaction(tx, usd_htg_rate: @usd_htg_rate)
    end
    Transfer.includes(user: { avatar_attachment: :blob }).order(created_at: :desc).limit(5).each do |t|
      ticker_items << Admin::ActivityItem.from_transfer(t, usd_htg_rate: @usd_htg_rate)
    end
    BankWithdrawal.includes(:user).order(created_at: :desc).limit(3).each do |bw|
      ticker_items << Admin::ActivityItem.from_bank_withdrawal(bw, usd_htg_rate: @usd_htg_rate)
    end
    @ticker_items = ticker_items.sort_by(&:created_at).reverse.first(5)

    # Balances loaded async via system_health endpoint
    @eth_balance  = nil
    @usd_balance = nil
    @moncash_prefunded_balance = nil
    @moncash_prefunded_error = nil
  end

  # ── Kredite page ──
  def credit
  end

  # ── POST credit wallet ──
  def credit_wallet
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to admin_credit_path, alert: "PIN transfè pa kòrèk."
      return
    end

    user = User.find_by(email: params[:email]) || User.find_by(cashtag: params[:email]&.delete_prefix("$"))
    unless user
      redirect_to admin_credit_path, alert: "Itilizatè pa jwenn: #{params[:email]}"
      return
    end

    wallet = user.ensure_wallet!
    amount = params[:amount].to_f
    asset = params[:asset].to_s.downcase

    if amount <= 0 || !%w[htg usd].include?(asset)
      redirect_to admin_credit_path, alert: "Montan oswa aktif pa valid."
      return
    end

    WalletService.new(wallet).deposit!(
      amount: amount,
      asset: asset,
      moncash_transaction_id: "admin-credit-#{current_user.id}-#{Time.current.to_i}",
      skip_limits: true
    )

    formatted = number_with_delimiter(sprintf("%.2f", amount))
    redirect_to admin_credit_path, notice: "#{formatted} #{asset.upcase} kredite nan kont #{user.email} ($#{user.cashtag})."
  end

  # ── POST credit to external Base address ──
  def credit_external
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to admin_credit_path, alert: "PIN transfè pa kòrèk."
      return
    end

    address = params[:wallet_address].to_s.strip
    amount  = params[:amount].to_f
    asset   = params[:asset].to_s.downcase

    # Validate address
    begin
      EthAddressValidator.validate!(address)
    rescue EthAddressValidator::InvalidAddressError => e
      redirect_to admin_credit_path, alert: "Adrès pa valid: #{e.message}"
      return
    end

    if amount <= 0
      redirect_to admin_credit_path, alert: "Montan pa valid."
      return
    end

    unless asset == "usd"
      redirect_to admin_credit_path, alert: "Sèlman USD sipòte pou adrès ekstèn Base."
      return
    end

    # Try to find the Zèllus user who owns this address
    recipient = User.find_by("LOWER(deposit_address) = ?", address.downcase) ||
                User.find_by("LOWER(circle_wallet_address) = ?", address.downcase)

    # Create a Transaction record — associate with recipient if found, else admin
    tx = Transaction.create!(
      user: recipient || current_user,
      transaction_type: :admin_credit_external,
      fiat_amount: amount,
      crypto_amount: amount,
      crypto_currency: :usd,
      destination_address: address,
      status: :paid,
      fee_amount: 0
    )

    CryptoTransferWorker.perform_async(tx.id)

    formatted = number_with_delimiter(sprintf("%.2f", amount))
    recipient_label = if recipient
                        "#{recipient.email} ($#{recipient.cashtag})"
    else
                        "#{address[0..5]}...#{address[-4..]}"
    end
    redirect_to admin_credit_path, notice: "#{formatted} USD ap voye sou Base → #{recipient_label}. TX #{tx.token} ap trete."
  end

  # ── GET /admin/system_health (JSON) — async balances ──
  def system_health
    rpc_url  = ENV["BASE_RPC_URL"].presence || "https://mainnet.base.org"
    priv_hex = ENV["TREASURY_PRIVATE_KEY"].to_s.strip.delete_prefix("0x")
    address  = derive_treasury_address(priv_hex)

    eth  = fetch_eth_balance(rpc_url, address)
    usd = fetch_usd_balance(rpc_url, address)

    moncash_balance = nil
    moncash_error   = nil
    begin
      prefunded = MoncashService.prefunded_balance_info
      if prefunded[:success]
        moncash_balance = prefunded[:balance]
      else
        moncash_error = prefunded[:error]
      end
    rescue => e
      moncash_error = e.message
    end

    # Internal wallet balances (database-tracked) — column is `usdc_balance`
    internal_usdc = Wallet.sum(:usdc_balance).to_f
    internal_htg  = Wallet.sum(:htg_balance).to_f

    # Reserve coverage (USDC only — HTG has no on-chain backing).
    # surplus = treasury - liabilities; ratio = treasury / liabilities.
    # When liabilities are zero, ratio is infinite — display as nil to
    # let the JS render "—" rather than "Infinityx".
    reserve_surplus = (usd - internal_usdc).round(2)
    reserve_ratio   = internal_usdc.positive? ? (usd / internal_usdc).round(2) : nil
    reserve_status  =
      if internal_usdc.zero?           then "healthy"
      elsif reserve_ratio >= 1.10      then "healthy"
      elsif reserve_ratio >= 1.00      then "tight"
      else                                  "insolvent"
      end

    # JSON keys match what the JS handlers expect (admin.html.erb +
    # dashboard/index.html.erb both read `usdc_balance` / `internal_usdc`).
    render json: {
      eth_balance: eth.round(6),
      usdc_balance: usd.round(2),
      internal_usdc: internal_usdc.round(2),
      internal_htg: internal_htg.round(0),
      moncash_balance: moncash_balance&.to_f&.round(0),
      moncash_error: moncash_error&.to_s&.truncate(30),
      gas_low: eth < 0.005,
      reserve_surplus: reserve_surplus,
      reserve_ratio: reserve_ratio,
      reserve_status: reserve_status
    }
  rescue => e
    Rails.logger.error "Admin system_health error: #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # ── Approve Pionye Loan ──
  def approve_loan
    @transaction = Transaction.find_by!(token: params[:id])

    unless @transaction.loan_request? && @transaction.pending?
      redirect_to admin_root_path, alert: "Invalid or already processed loan request."
      return
    end

    begin
      prefunded_info = MoncashService.prefunded_balance_info
      if prefunded_info[:success]
        current_balance = prefunded_info[:balance].to_f
        if current_balance < @transaction.fiat_amount.to_f
          redirect_to admin_root_path, alert: "Bank Liquidity Error: Payout requires #{@transaction.fiat_amount} HTG, but only #{current_balance} HTG available in MonCash."
          return
        end
      else
        redirect_to admin_root_path, alert: "MonCash API Error: Could not verify bank balance. Payout aborted."
        return
      end
    rescue => e
      Rails.logger.error "Liquidity Check Error: #{e.message}"
      redirect_to admin_root_path, alert: "System Error during liquidity check. Please try again."
      return
    end

    @transaction.update!(status: :crypto_sent, failure_reason: nil)
    SellTransferWorker.perform_async(@transaction.id)
    redirect_to admin_root_path, notice: "Pionye Loan approved. MonCash payout of #{@transaction.fiat_amount} HTG queued for #{@transaction.user.email}."
  end

  def retry_transaction
    @transaction = Transaction.find_by!(token: params[:id])

    if @transaction.blockchain_tx_hash.blank?
      @transaction.update!(status: :paid, failure_reason: nil)
      CryptoTransferWorker.perform_async(@transaction.id)
      redirect_to admin_root_path, notice: "Retry initiated for Transaction ##{@transaction.id}."
    else
      redirect_to admin_root_path, alert: "This transaction already has a blockchain hash."
    end
  end

  def retry_payout
    @transaction = Transaction.find_by!(token: params[:id])

    unless @transaction.sell? && @transaction.payout_failed?
      redirect_to admin_root_path, alert: "Only sell transactions with payout failure can be retried."
      return
    end

    unless @transaction.blockchain_tx_hash.present?
      redirect_to admin_root_path, alert: "Cannot retry payout without a confirmed deposit transaction hash."
      return
    end

    @transaction.update!(status: :crypto_sent, failure_reason: nil)
    SellTransferWorker.perform_async(@transaction.id)
    redirect_to admin_root_path, notice: "MonCash payout retry queued for Transaction ##{@transaction.id}."
  end

  # ── Bank Withdrawal actions ──
  def process_bank_withdrawal
    bw = BankWithdrawal.find(params[:id])
    unless bw.pending?
      redirect_to admin_root_path, alert: "Retrè bank sa a pa an atant."
      return
    end

    bw.update!(status: :processing, processed_at: Time.current)
    redirect_to admin_root_path, notice: "Retrè bank ##{bw.id} make kòm 'Ap Trete'."
  end

  def complete_bank_withdrawal
    bw = BankWithdrawal.find(params[:id])
    unless bw.processing?
      redirect_to admin_root_path, alert: "Retrè bank sa a pa ap trete."
      return
    end

    bw.update!(
      status: :completed,
      reference_number: params[:reference_number].to_s.strip.presence,
      completed_at: Time.current
    )

    begin
      WalletMailer.with(
        user_id: bw.user_id, amount: bw.amount.to_f, asset: "htg",
        bank_name: bw.bank_name, bank_account: bw.bank_account_number,
        reference_number: bw.reference_number
      ).bank_withdrawal_completed.deliver_later
    rescue => e
      Rails.logger.error "Bank withdrawal completed email failed: #{e.message}"
    end

    redirect_to admin_root_path, notice: "Retrè bank ##{bw.id} fini! Ref: #{bw.reference_number || '—'}"
  end

  def fail_bank_withdrawal
    bw = BankWithdrawal.find(params[:id])
    unless bw.pending? || bw.processing?
      redirect_to admin_root_path, alert: "Retrè bank sa a deja fini oswa echwe."
      return
    end

    admin_note = params[:admin_note].to_s.strip.presence || "Anile pa admin"

    ActiveRecord::Base.transaction do
      bw.update!(status: :failed, admin_note: admin_note)
      wallet = bw.user.ensure_wallet!
      WalletService.new(wallet).refund!(
        amount: bw.amount,
        asset: "htg",
        reference: bw,
        reason: "Ranbousman retrè bank ##{bw.id} — #{admin_note}"
      )
    end

    begin
      WalletMailer.with(
        user_id: bw.user_id, amount: bw.amount.to_f, asset: "htg",
        bank_name: bw.bank_name, bank_account: bw.bank_account_number,
        reason: admin_note
      ).bank_withdrawal_failed.deliver_later
    rescue => e
      Rails.logger.error "Bank withdrawal failed email failed: #{e.message}"
    end

    redirect_to admin_root_path, notice: "Retrè bank ##{bw.id} echwe. #{bw.amount.to_i} HTG ranbouse nan pòtfèy itilizatè a."
  end

  # ── Tout Aktivite (unified feed) ──
  def activity
    @usd_htg_rate = begin; RateService.usd_htg_rate; rescue; 135.50; end
    type_filter = params[:type].presence
    search_q = params[:q].to_s.strip.presence
    date_filter = params[:date].presence

    items = []

    # Transactions (unless filtering to transfers/bank_withdrawals only)
    unless type_filter.in?(%w[transfer bank_withdrawal])
      txs = Transaction.includes(user: [ :business, { avatar_attachment: :blob } ])
      if type_filter == "buy"
        txs = txs.where(transaction_type: :buy)
      elsif type_filter == "sell"
        txs = txs.where(transaction_type: :sell)
      elsif type_filter == "loan"
        txs = txs.where(transaction_type: :loan_request)
      end
      if search_q
        txs = txs.joins(:user).where(
          "users.cashtag ILIKE :q OR transactions.token ILIKE :q OR users.email ILIKE :q",
          q: "%#{search_q}%"
        )
      end
      if date_filter
        txs = txs.where("transactions.created_at::date = ?", date_filter)
      end
      txs.order(created_at: :desc).limit(100).each do |tx|
        items << Admin::ActivityItem.from_transaction(tx, usd_htg_rate: @usd_htg_rate)
      end
    end

    # Transfers
    unless type_filter.in?(%w[buy sell loan bank_withdrawal])
      transfers = Transfer.includes(user: [ :business, { avatar_attachment: :blob } ])
      if search_q
        transfers = transfers.joins(:user).where(
          "users.cashtag ILIKE :q OR transfers.token ILIKE :q OR users.email ILIKE :q",
          q: "%#{search_q}%"
        )
      end
      if date_filter
        transfers = transfers.where("transfers.created_at::date = ?", date_filter)
      end
      transfers.order(created_at: :desc).limit(100).each do |t|
        items << Admin::ActivityItem.from_transfer(t, usd_htg_rate: @usd_htg_rate)
      end
    end

    # Bank Withdrawals
    unless type_filter.in?(%w[buy sell loan transfer])
      bws = BankWithdrawal.includes(:user)
      if search_q
        bws = bws.joins(:user).where(
          "users.cashtag ILIKE :q OR users.email ILIKE :q",
          q: "%#{search_q}%"
        )
      end
      if date_filter
        bws = bws.where("bank_withdrawals.created_at::date = ?", date_filter)
      end
      bws.order(created_at: :desc).limit(50).each do |bw|
        items << Admin::ActivityItem.from_bank_withdrawal(bw, usd_htg_rate: @usd_htg_rate)
      end
    end

    # Sort merged list by created_at desc and paginate
    @items = items.sort_by(&:created_at).reverse
    page = (params[:page] || 1).to_i
    per_page = 25
    @total_pages = (@items.size.to_f / per_page).ceil
    @current_page = page
    @items = @items.slice((page - 1) * per_page, per_page) || []
  end

  # ── Activity Detail ──
  def activity_show
    @usd_htg_rate = begin; RateService.usd_htg_rate; rescue; 135.50; end
    type = params[:activity_type]
    id = params[:id]

    case type
    when "transaction"
      record = Transaction.includes(user: [ :business, { avatar_attachment: :blob } ]).find(id)
      @item = Admin::ActivityItem.from_transaction(record, usd_htg_rate: @usd_htg_rate)
    when "transfer"
      record = Transfer.includes(user: [ :business, { avatar_attachment: :blob } ]).find(id)
      @item = Admin::ActivityItem.from_transfer(record, usd_htg_rate: @usd_htg_rate)
    when "bank_withdrawal"
      record = BankWithdrawal.includes(:user).find(id)
      @item = Admin::ActivityItem.from_bank_withdrawal(record, usd_htg_rate: @usd_htg_rate)
    else
      redirect_to admin_activity_path, alert: "Tip aktivite pa valid."
      nil
    end
  end

  # ── Chart Data (JSON for ApexCharts) ──
  def chart_data
    range = params[:range] || "week"
    usd_htg_rate = begin; RateService.usd_htg_rate; rescue; 135.50; end

    active_statuses = [ :paid, :crypto_sent, :completed ]
    txs = Transaction.where(status: active_statuses)

    # Determine date range and SQL grouping
    now = Time.current
    case range
    when "hour"
      start_time = 60.minutes.ago
      group_expr = "date_trunc('minute', created_at)"
    when "day"
      start_time = 24.hours.ago
      group_expr = "date_trunc('hour', created_at)"
    when "week"
      start_time = 7.days.ago
      group_expr = "date_trunc('day', created_at)"
    when "month"
      start_time = 30.days.ago
      group_expr = "date_trunc('day', created_at)"
    when "year"
      start_time = 12.months.ago
      group_expr = "date_trunc('month', created_at)"
    else
      start_time = 7.days.ago
      group_expr = "date_trunc('day', created_at)"
    end

    tx_data = txs.where("created_at >= ?", start_time)
                 .group(Arel.sql(group_expr))
                 .order(Arel.sql(group_expr))
                 .sum(:fee_amount)

    # Wallet ledger fees (conversion, withdrawal, transfer) — convert USD fees to HTG
    ledger_htg = WalletLedgerEntry.where(entry_type: %w[fee instant_fee conversion_fee], asset: "htg")
                                  .where("created_at >= ?", start_time)
                                  .group(Arel.sql(group_expr))
                                  .order(Arel.sql(group_expr))
                                  .sum(:amount)

    ledger_usd = WalletLedgerEntry.where(entry_type: %w[fee instant_fee conversion_fee], asset: "usd")
                                  .where("created_at >= ?", start_time)
                                  .group(Arel.sql(group_expr))
                                  .order(Arel.sql(group_expr))
                                  .sum(:amount)

    # Merge all fee sources by time bucket
    all_times = (tx_data.keys + ledger_htg.keys + ledger_usd.keys).uniq.sort
    data = all_times.map do |time|
      htg = (tx_data[time] || 0).to_f + (ledger_htg[time] || 0).to_f + ((ledger_usd[time] || 0).to_f * usd_htg_rate)
      [ time, htg ]
    end.to_h

    series = data.map do |time, htg|
      usd = usd_htg_rate > 0 ? (htg.to_f / usd_htg_rate).round(2) : 0
      {
        x: time.to_i * 1000, # JS timestamp
        htg: htg.to_f.round(2),
        usd: usd
      }
    end

    render json: {
      series: series,
      total_htg: series.sum { |s| s[:htg] }.round(2),
      total_usd: series.sum { |s| s[:usd] }.round(2),
      range: range
    }
  end

  # ── Reveal Treasury Address (PIN-protected) ──
  def reveal_treasury
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to admin_root_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

    priv_hex = ENV["TREASURY_PRIVATE_KEY"].to_s.strip.delete_prefix("0x")
    address  = derive_treasury_address(priv_hex)

    flash[:treasury_address] = address
    redirect_to admin_root_path
  rescue => e
    Rails.logger.error "reveal_treasury error: #{e.class} — #{e.message}"
    redirect_to admin_root_path, alert: "Erè inatandi. Eseye ankò."
  end

  private

  def derive_treasury_address(priv_hex)
    priv_bn   = OpenSSL::BN.new(priv_hex.rjust(64, "0"), 16)
    group     = OpenSSL::PKey::EC::Group.new("secp256k1")
    pub_point = group.generator.mul(priv_bn)
    pub_bytes = pub_point.to_octet_string(:uncompressed)[1..]
    addr_hash = Digest::Keccak.digest(pub_bytes, 256)
    "0x" + addr_hash.unpack1("H*")[-40..]
  end

  def fetch_eth_balance(rpc_url, address)
    result = rpc_call(rpc_url, "eth_getBalance", [ address, "latest" ])
    result.to_i(16).to_f / 10**18
  end

  def fetch_usd_balance(rpc_url, address)
    usd_address = CryptoTransferWorker::USD_ADDRESS
    padded = address.delete_prefix("0x").downcase.rjust(64, "0")
    data   = "0x70a08231#{padded}"
    result = rpc_call(rpc_url, "eth_call", [ { to: usd_address, data: data }, "latest" ])
    result.to_i(16).to_f / 10**6
  end

  def rpc_call(rpc_url, method, params)
    conn = Faraday.new(url: rpc_url)
    response = conn.post do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
    end
    body = JSON.parse(response.body)
    raise "RPC error (#{method}): #{body['error']}" if body["error"]
    body["result"]
  end
end

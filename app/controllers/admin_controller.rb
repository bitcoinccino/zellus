require 'faraday'
require 'openssl'
require 'digest/keccak'

class AdminController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_admin!

  def dashboard
    # 1. Financial Overviews
    @total_fees          = Transaction.where(status: [:paid, :crypto_sent, :completed]).sum(:fee_amount)
    @total_volume        = Transaction.where(status: [:paid, :crypto_sent, :completed]).sum(:fiat_amount)
    @tx_processed        = Transaction.where(status: :completed).count
    @recent_transactions = Transaction.includes(:user).order(created_at: :desc).limit(15)

    # 2. PIONYE LOAN REQUESTS (New Feature)
    # Fetching pending loans from verified Malfini/Fokon members
    @loan_requests = Transaction.includes(:user)
                                .where(transaction_type: :loan_request, status: :pending)
                                .order(created_at: :desc)

    # Bank Withdrawals (pending/processing)
    @pending_bank_withdrawals = BankWithdrawal.includes(:user)
                                              .where(status: %w[pending processing])
                                              .order(created_at: :asc)

    @moncash_prefunded_balance = nil
    @moncash_prefunded_error = nil

    # 3. Live Treasury Balances (RPC)
    begin
      rpc_url          = ENV['BASE_RPC_URL'].presence || "https://mainnet.base.org"
      priv_hex         = ENV['TREASURY_PRIVATE_KEY'].to_s.strip.delete_prefix("0x")
      treasury_address = derive_treasury_address(priv_hex)

      @eth_balance  = fetch_eth_balance(rpc_url, treasury_address)
      @usdc_balance = fetch_usdc_balance(rpc_url, treasury_address)
    rescue => e
      @eth_balance  = 0.0
      @usdc_balance = 0.0
      Rails.logger.error "Admin Treasury Fetch Error: #{e.message}"
    end

    # 4. MonCash Prefunded Balance
    begin
      prefunded = MoncashService.prefunded_balance_info
      @moncash_prefunded_balance = prefunded[:balance] if prefunded[:success]
      @moncash_prefunded_error   = prefunded[:error] unless prefunded[:success]
    rescue => e
      @moncash_prefunded_balance = nil
      @moncash_prefunded_error = e.message
      Rails.logger.error "Admin MonCash Prefunded Fetch Error: #{e.message}"
    end
  end

  # NEW ACTION: Approve Pionye Loan and trigger MonCash Payout
  # app/controllers/admin_controller.rb

def approve_loan
  @transaction = Transaction.find_by!(token: params[:id])

  # 1. Standard Guard: Ensure it's a valid pending loan
  unless @transaction.loan_request? && @transaction.pending?
    redirect_to admin_dashboard_path, alert: "Invalid or already processed loan request."
    return
  end

  # 2. LIQUIDITY GUARD: Check if the Bank has enough HTG in MonCash
  begin
    prefunded_info = MoncashService.prefunded_balance_info
    
    if prefunded_info[:success]
      current_balance = prefunded_info[:balance].to_f
      
      if current_balance < @transaction.fiat_amount.to_f
        redirect_to admin_dashboard_path, 
          alert: "Bank Liquidity Error: Payout requires #{@transaction.fiat_amount} HTG, but only #{current_balance} HTG available in MonCash."
        return
      end
    else
      # If the API check fails entirely, don't risk the payout
      redirect_to admin_dashboard_path, alert: "MonCash API Error: Could not verify bank balance. Payout aborted."
      return
    end
  rescue => e
    Rails.logger.error "Liquidity Check Error: #{e.message}"
    redirect_to admin_dashboard_path, alert: "System Error during liquidity check. Please try again."
    return
  end

  # 3. Success Path: If funds are sufficient, proceed
  @transaction.update!(status: :crypto_sent, failure_reason: nil)

  # Trigger the Payout Worker
  SellTransferWorker.perform_async(@transaction.id)

  redirect_to admin_dashboard_path, notice: "Pionye Loan approved. MonCash payout of #{@transaction.fiat_amount} HTG queued for #{@transaction.user.email}."
end


  def retry_transaction
    @transaction = Transaction.find_by!(token: params[:id])

    if @transaction.blockchain_tx_hash.blank?
      @transaction.update!(status: :paid, failure_reason: nil)
      CryptoTransferWorker.perform_async(@transaction.id)
      redirect_to admin_dashboard_path, notice: "Retry initiated for Transaction ##{@transaction.id}."
    else
      redirect_to admin_dashboard_path, alert: "This transaction already has a blockchain hash."
    end
  end

  # ── Invite Codes ──
  def invite_codes
    @invite_codes = InviteCode.includes(:creator).order(created_at: :desc)
    @new_invite_code = InviteCode.new(region: "cotes_de_fer", max_uses: 1)
    @regions = InviteCode::REGIONS
    @total_signups = User.where.not(invite_code_id: nil).count
  end

  def create_invite_code
    batch_size = params[:batch_size].to_i.clamp(1, 50)
    region = params[:invite_code][:region]
    max_uses = params[:invite_code][:max_uses].to_i
    label = params[:invite_code][:label].presence
    expires_in = params[:expires_in].to_i # days, 0 = never

    created = 0
    batch_size.times do
      code = InviteCode.new(
        region: region,
        max_uses: max_uses,
        label: label,
        creator: current_user,
        expires_at: expires_in > 0 ? expires_in.days.from_now : nil
      )
      created += 1 if code.save
    end

    redirect_to admin_invite_codes_path, notice: "#{created} kòd envitasyon kreye pou #{InviteCode::REGIONS[region]}."
  end

  def credit_wallet
    user = User.find_by(email: params[:email]) || User.find_by(cashtag: params[:email]&.delete_prefix("$"))
    unless user
      redirect_to admin_dashboard_path, alert: "Itilizatè pa jwenn: #{params[:email]}"
      return
    end

    wallet = user.ensure_wallet!
    amount = params[:amount].to_f
    asset = params[:asset].to_s.downcase

    if amount <= 0 || !%w[htg usdc].include?(asset)
      redirect_to admin_dashboard_path, alert: "Montan oswa aktif pa valid."
      return
    end

    WalletService.new(wallet).deposit!(
      amount: amount,
      asset: asset,
      moncash_transaction_id: "admin-credit-#{current_user.id}-#{Time.current.to_i}"
    )

    redirect_to admin_dashboard_path, notice: "#{amount} #{asset.upcase} kredite nan kont #{user.email} ($#{user.cashtag})."
  end

  # ── Bank Withdrawal: Mark as "processing" (admin started manual transfer) ──
  def process_bank_withdrawal
    bw = BankWithdrawal.find(params[:id])
    unless bw.pending?
      redirect_to admin_dashboard_path, alert: "Retrè bank sa a pa an atant."
      return
    end

    bw.update!(status: :processing, processed_at: Time.current)
    redirect_to admin_dashboard_path, notice: "Retrè bank ##{bw.id} make kòm 'Ap Trete'."
  end

  # ── Bank Withdrawal: Mark as "completed" with reference number ──
  def complete_bank_withdrawal
    bw = BankWithdrawal.find(params[:id])
    unless bw.processing?
      redirect_to admin_dashboard_path, alert: "Retrè bank sa a pa ap trete."
      return
    end

    bw.update!(
      status: :completed,
      reference_number: params[:reference_number].to_s.strip.presence,
      completed_at: Time.current
    )

    # Send completion email
    begin
      WalletMailer.with(
        user_id: bw.user_id, amount: bw.amount.to_f, asset: "htg",
        bank_name: bw.bank_name, bank_account: bw.bank_account_number,
        reference_number: bw.reference_number
      ).bank_withdrawal_completed.deliver_later
    rescue => e
      Rails.logger.error "Bank withdrawal completed email failed: #{e.message}"
    end

    redirect_to admin_dashboard_path, notice: "Retrè bank ##{bw.id} fini! Ref: #{bw.reference_number || '—'}"
  end

  # ── Bank Withdrawal: Mark as "failed" + refund user ──
  def fail_bank_withdrawal
    bw = BankWithdrawal.find(params[:id])
    unless bw.pending? || bw.processing?
      redirect_to admin_dashboard_path, alert: "Retrè bank sa a deja fini oswa echwe."
      return
    end

    admin_note = params[:admin_note].to_s.strip.presence || "Anile pa admin"

    ActiveRecord::Base.transaction do
      bw.update!(status: :failed, admin_note: admin_note)

      # Refund user's wallet
      wallet = bw.user.ensure_wallet!
      WalletService.new(wallet).refund!(
        amount: bw.amount,
        asset: "htg",
        reference: bw,
        reason: "Ranbousman retrè bank ##{bw.id} — #{admin_note}"
      )
    end

    # Send failure + refund email
    begin
      WalletMailer.with(
        user_id: bw.user_id, amount: bw.amount.to_f, asset: "htg",
        bank_name: bw.bank_name, bank_account: bw.bank_account_number,
        reason: admin_note
      ).bank_withdrawal_failed.deliver_later
    rescue => e
      Rails.logger.error "Bank withdrawal failed email failed: #{e.message}"
    end

    redirect_to admin_dashboard_path, notice: "Retrè bank ##{bw.id} echwe. #{bw.amount.to_i} HTG ranbouse nan pòtfèy itilizatè a."
  end

  def toggle_invite_code
    code = InviteCode.find(params[:id])
    code.update!(active: !code.active?)
    redirect_to admin_invite_codes_path, notice: "Kòd #{code.code} #{code.active? ? 'aktive' : 'dezaktive'}."
  end

  def retry_payout
    @transaction = Transaction.find_by!(token: params[:id])

    unless @transaction.sell? && @transaction.payout_failed?
      redirect_to admin_dashboard_path, alert: "Only sell transactions with payout failure can be retried."
      return
    end

    unless @transaction.blockchain_tx_hash.present?
      redirect_to admin_dashboard_path, alert: "Cannot retry payout without a confirmed deposit transaction hash."
      return
    end

    @transaction.update!(status: :crypto_sent, failure_reason: nil)
    SellTransferWorker.perform_async(@transaction.id)
    redirect_to admin_dashboard_path, notice: "MonCash payout retry queued for Transaction ##{@transaction.id}."
  end

  private

  def ensure_admin!
    admin_email = ENV['ADMIN_EMAIL'].to_s.strip
    unless current_user.email == admin_email
      redirect_to root_path, alert: "Authorized personnel only."
    end
  end

  def derive_treasury_address(priv_hex)
    priv_bn   = OpenSSL::BN.new(priv_hex.rjust(64, "0"), 16)
    group     = OpenSSL::PKey::EC::Group.new("secp256k1")
    pub_point = group.generator.mul(priv_bn)
    pub_bytes = pub_point.to_octet_string(:uncompressed)[1..]
    addr_hash = Digest::Keccak.digest(pub_bytes, 256)
    "0x" + addr_hash.unpack1("H*")[-40..]
  end

  def fetch_eth_balance(rpc_url, address)
    result = rpc_call(rpc_url, "eth_getBalance", [address, "latest"])
    result.to_i(16).to_f / 10**18
  end

  def fetch_usdc_balance(rpc_url, address)
    usdc_address = CryptoTransferWorker::USDC_ADDRESS
    padded = address.delete_prefix("0x").downcase.rjust(64, "0")
    data   = "0x70a08231#{padded}"
    result = rpc_call(rpc_url, "eth_call", [{ to: usdc_address, data: data }, "latest"])
    result.to_i(16).to_f / 10**6
  end

  def rpc_call(rpc_url, method, params)
    conn = Faraday.new(url: rpc_url)
    response = conn.post do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
    end
    body = JSON.parse(response.body)
    raise "RPC error (#{method}): #{body['error']}" if body["error"]
    body["result"]
  end
end

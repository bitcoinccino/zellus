# frozen_string_literal: true
require 'sidekiq'

class WbtcDepositMonitorWorker
  include Sidekiq::Job

  # Base Mainnet wBTC
  WBTC_ADDRESS   = ENV.fetch("WBTC_CONTRACT_ADDRESS", "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c")
  WBTC_DECIMALS  = 8
  MONITOR_NAME   = "wbtc_base_mainnet"
  POLL_RANGE     = 200    # max blocks per poll (smaller to avoid RPC limits)
  REQUEUE_DELAY  = 300    # seconds between polls (5 min)
  BATCH_SIZE     = 50     # max addresses per eth_getLogs query

  # ERC-20 Transfer(address indexed from, address indexed to, uint256 value)
  TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  # Max deposits per user per hour (anti-dust-spam)
  DEPOSIT_RATE_LIMIT = 20

  def perform
    # wBTC deposits disabled (HTG + USD only mode)
    Rails.logger.info "WbtcDepositMonitor: paused (HTG+USD only mode)"
    return

    rpc_url = ENV['BASE_RPC_URL'].presence || "https://mainnet.base.org"

    # Build lookup of ALL user deposit addresses → user_id
    @address_to_user = {}
    User.where.not(deposit_address: [nil, ""]).find_each do |user|
      @address_to_user[user.deposit_address.downcase] = user.id
    end

    # Also include treasury address
    treasury = CryptoKeyHelper.treasury_address
    @treasury = treasury&.downcase

    if @address_to_user.empty? && @treasury.blank?
      Rails.logger.warn "WbtcDepositMonitor: no deposit addresses to monitor, skipping"
      schedule_next
      return
    end

    # All addresses to monitor (user deposit addresses + treasury)
    all_addresses = @address_to_user.keys.dup
    all_addresses << @treasury if @treasury.present? && !all_addresses.include?(@treasury)

    monitor = BlockchainDepositMonitor.find_or_create_by!(name: MONITOR_NAME)
    current_block = rpc_call(rpc_url, "eth_blockNumber", []).to_i(16)

    from_block = if monitor.last_processed_block > 0
                   monitor.last_processed_block + 1
                 else
                   [current_block - POLL_RANGE, 0].max
                 end
    to_block = [from_block + POLL_RANGE - 1, current_block].min

    if from_block > current_block
      schedule_next
      return
    end

    # Query in batches (eth_getLogs topics array has practical limits)
    deposits_count = 0
    all_addresses.each_slice(BATCH_SIZE) do |batch|
      padded_batch = batch.map { |addr| "0x" + addr.delete_prefix("0x").rjust(64, '0') }

      logs = rpc_call(rpc_url, "eth_getLogs", [{
        fromBlock: "0x#{from_block.to_s(16)}",
        toBlock:   "0x#{to_block.to_s(16)}",
        address:   WBTC_ADDRESS,
        topics:    [TRANSFER_TOPIC, nil, padded_batch]
      }])

      (logs || []).each do |log|
        if process_deposit_log(log)
          deposits_count += 1
        end
      end
    end

    monitor.update!(last_processed_block: to_block)
    Rails.logger.info "WbtcDepositMonitor: scanned blocks #{from_block}..#{to_block}, monitoring #{all_addresses.size} addresses, found #{deposits_count} deposit(s)"

    # If more blocks remain, process immediately; otherwise wait
    if to_block < current_block
      WbtcDepositMonitorWorker.perform_async
    else
      schedule_next
    end

  rescue => e
    Rails.logger.error "WbtcDepositMonitor error: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    schedule_next
  end

  private

  def process_deposit_log(log)
    tx_hash = log["transactionHash"]
    return false if tx_hash.blank?

    # Extract sender (from) and receiver (to) from topics
    from_topic = log.dig("topics", 1)
    to_topic   = log.dig("topics", 2)
    return false if from_topic.blank? || to_topic.blank?

    sender_address   = "0x" + from_topic[-40..]
    receiver_address = "0x" + to_topic[-40..]

    # Skip self-transfers from treasury
    if @treasury.present? && sender_address.downcase == @treasury
      Rails.logger.debug "WbtcDepositMonitor: skipping self-transfer from treasury, tx=#{tx_hash}"
      return false
    end

    # Extract amount from data (uint256, wBTC = 8 decimals)
    raw_amount = log["data"].to_s.delete_prefix("0x").to_i(16)
    wbtc_amount = BigDecimal(raw_amount.to_s) / BigDecimal(10.pow(WBTC_DECIMALS).to_s)
    return false if wbtc_amount <= 0

    # Find the user who owns this deposit address
    user_id = @address_to_user[receiver_address.downcase]

    unless user_id
      # Might be a transfer to treasury — try matching sender to a PaymentMethod (legacy flow)
      if @treasury.present? && receiver_address.downcase == @treasury
        return process_treasury_deposit(sender_address, wbtc_amount, tx_hash)
      end

      Rails.logger.info "WbtcDepositMonitor: unmatched deposit to #{receiver_address.first(10)}…, tx=#{tx_hash.first(10)}…"
      return false
    end

    user = User.find_by(id: user_id)
    return false unless user

    credit_user(user, wbtc_amount, tx_hash)
  end

  # Legacy: match transfers to treasury by sender's PaymentMethod
  def process_treasury_deposit(sender_address, wbtc_amount, tx_hash)
    payment_method = PaymentMethod.where(
      active: true,
      category: "crypto_wallet",
      provider: "base"
    ).where("LOWER(wallet_address) = ?", sender_address.downcase)
     .order(created_at: :desc).first

    # Skip if sender is treasury itself
    if payment_method && @treasury.present? && payment_method.wallet_address.downcase == @treasury
      return false
    end

    unless payment_method
      Rails.logger.info "WbtcDepositMonitor: unmatched treasury deposit from #{sender_address.first(10)}…, tx=#{tx_hash.first(10)}…"
      return false
    end

    credit_user(payment_method.user, wbtc_amount, tx_hash)
  end

  def credit_user(user, wbtc_amount, tx_hash)
    # Rate limit: skip if user received too many deposits recently
    recent_count = user.notifications.where(notification_type: "transfer_received")
                       .where("created_at > ?", 1.hour.ago).count
    if recent_count >= DEPOSIT_RATE_LIMIT
      Rails.logger.warn "WbtcDepositMonitor: rate limit hit for user=#{user.id} (#{recent_count} deposits/hr), skipping notification"
    end

    wallet = user.ensure_wallet!

    WalletService.new(wallet).deposit!(
      amount: wbtc_amount,
      asset: "wbtc",
      moncash_transaction_id: tx_hash
    )

    Rails.logger.info "WbtcDepositMonitor: credited user=#{user.id}"

    # In-app notification (throttled)
    if recent_count < DEPOSIT_RATE_LIMIT
      NotificationService.crypto_deposit_received(user, wbtc_amount, "wbtc", tx_hash)
    end

    # Send notification email (throttled)
    if recent_count < DEPOSIT_RATE_LIMIT
      begin
        WalletMailer.with(user_id: user.id, amount: wbtc_amount.to_f, asset: "wbtc", tx_hash: tx_hash)
                    .deposit_confirmed.deliver_later
      rescue => e
        Rails.logger.error "WbtcDepositMonitor: email failed for user=#{user.id}: #{e.message}"
      end
    end

    true
  rescue WalletService::DuplicateDepositError
    Rails.logger.info "WbtcDepositMonitor: duplicate deposit skipped, tx=#{tx_hash}"
    false
  rescue => e
    Rails.logger.error "WbtcDepositMonitor: deposit failed for user=#{user.id}, tx=#{tx_hash.first(10)}…: #{e.message}"
    false
  end

  def schedule_next
    WbtcDepositMonitorWorker.perform_in(REQUEUE_DELAY.seconds)
  end

  # ── JSON-RPC (delegated to BaseRpcClient with retry/backoff) ──────────

  def rpc_call(url, method, params)
    @rpc_client ||= BaseRpcClient.new(url: url)
    @rpc_client.call(method, params)
  end
end

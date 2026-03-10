# frozen_string_literal: true
require 'sidekiq'

class EthDepositMonitorWorker
  include Sidekiq::Job

  MONITOR_NAME   = "eth_base_mainnet"
  POLL_RANGE     = 200    # blocks per poll — keep small for per-block scanning
  REQUEUE_DELAY  = 300    # seconds between polls (5 min)
  BATCH_SIZE     = 50     # max addresses per block scan

  # Max deposits per user per hour (anti-dust-spam)
  DEPOSIT_RATE_LIMIT = 20

  def perform
    # ETH deposits disabled (HTG + USD only mode)
    Rails.logger.info "EthDepositMonitor: paused (HTG+USD only mode)"
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
      Rails.logger.warn "EthDepositMonitor: no deposit addresses to monitor, skipping"
      schedule_next
      return
    end

    # All addresses to monitor (user deposit addresses + treasury)
    @all_addresses = Set.new(@address_to_user.keys)
    @all_addresses << @treasury if @treasury.present?

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

    deposits_count = 0

    # Scan each block for native ETH transfers to any monitored address
    (from_block..to_block).each do |block_num|
      block_hex = "0x#{block_num.to_s(16)}"
      block_data = rpc_call(rpc_url, "eth_getBlockByNumber", [block_hex, true])
      next unless block_data && block_data["transactions"]

      block_data["transactions"].each do |tx|
        next unless tx.is_a?(Hash)

        receiver = tx["to"].to_s.downcase
        next unless @all_addresses.include?(receiver)

        value_wei = tx["value"].to_s.delete_prefix("0x").to_i(16)
        next if value_wei <= 0

        # Skip contract calls (has input data beyond "0x")
        input = tx["input"].to_s
        next if input.length > 2

        # Skip self-transfers from treasury
        sender = tx["from"].to_s.downcase
        next if @treasury.present? && sender == @treasury

        if process_eth_deposit(tx, value_wei, receiver, sender)
          deposits_count += 1
        end
      end
    end

    monitor.update!(last_processed_block: to_block)
    Rails.logger.info "EthDepositMonitor: scanned blocks #{from_block}..#{to_block}, monitoring #{@all_addresses.size} addresses, found #{deposits_count} deposit(s)"

    # If more blocks remain, process immediately; otherwise wait
    if to_block < current_block
      EthDepositMonitorWorker.perform_async
    else
      schedule_next
    end

  rescue => e
    Rails.logger.error "EthDepositMonitor error: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    schedule_next
  end

  private

  def process_eth_deposit(tx, value_wei, receiver_address, sender_address)
    tx_hash = tx["hash"]
    return false if tx_hash.blank?

    eth_amount = BigDecimal(value_wei.to_s) / BigDecimal("1000000000000000000") # 18 decimals
    return false if eth_amount <= 0

    # Find the user who owns this deposit address
    user_id = @address_to_user[receiver_address]

    unless user_id
      # Might be a transfer to treasury — try matching sender to a PaymentMethod (legacy flow)
      if @treasury.present? && receiver_address == @treasury
        return process_treasury_deposit(sender_address, eth_amount, tx_hash)
      end

      Rails.logger.info "EthDepositMonitor: unmatched deposit to #{receiver_address.first(10)}…, tx=#{tx_hash.first(10)}…"
      return false
    end

    user = User.find_by(id: user_id)
    return false unless user

    credit_user(user, eth_amount, tx_hash)
  end

  # Legacy: match transfers to treasury by sender's PaymentMethod
  def process_treasury_deposit(sender_address, eth_amount, tx_hash)
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
      Rails.logger.info "EthDepositMonitor: unmatched treasury deposit from #{sender_address.first(10)}…, tx=#{tx_hash.first(10)}…"
      return false
    end

    credit_user(payment_method.user, eth_amount, tx_hash)
  end

  def credit_user(user, eth_amount, tx_hash)
    # Rate limit: skip if user received too many deposits recently
    recent_count = user.notifications.where(notification_type: "transfer_received")
                       .where("created_at > ?", 1.hour.ago).count
    if recent_count >= DEPOSIT_RATE_LIMIT
      Rails.logger.warn "EthDepositMonitor: rate limit hit for user=#{user.id} (#{recent_count} deposits/hr), skipping notification"
    end

    wallet = user.ensure_wallet!

    WalletService.new(wallet).deposit!(
      amount: eth_amount,
      asset: "eth",
      moncash_transaction_id: tx_hash
    )

    Rails.logger.info "EthDepositMonitor: credited user=#{user.id}"

    # In-app notification (throttled)
    if recent_count < DEPOSIT_RATE_LIMIT
      NotificationService.crypto_deposit_received(user, eth_amount, "eth", tx_hash)
    end

    # Send notification email (throttled)
    if recent_count < DEPOSIT_RATE_LIMIT
      begin
        WalletMailer.with(user_id: user.id, amount: eth_amount.to_f, asset: "eth", tx_hash: tx_hash)
                    .deposit_confirmed.deliver_later
      rescue => e
        Rails.logger.error "EthDepositMonitor: email failed for user=#{user.id}: #{e.message}"
      end
    end

    true
  rescue WalletService::DuplicateDepositError
    Rails.logger.info "EthDepositMonitor: duplicate deposit skipped, tx=#{tx_hash}"
    false
  rescue => e
    Rails.logger.error "EthDepositMonitor: deposit failed for user=#{user.id}, tx=#{tx_hash.first(10)}…: #{e.message}"
    false
  end

  def schedule_next
    EthDepositMonitorWorker.perform_in(REQUEUE_DELAY.seconds)
  end

  # ── JSON-RPC (delegated to BaseRpcClient with retry/backoff) ──────────

  def rpc_call(url, method, params)
    @rpc_client ||= BaseRpcClient.new(url: url)
    @rpc_client.call(method, params)
  end
end

# frozen_string_literal: true
require 'sidekiq'
require 'faraday'

class TransactionConfirmationWorker
  include Sidekiq::Job

  # Poll every 15 seconds, give up after 20 attempts (~5 minutes)
  MAX_ATTEMPTS = 20

  def perform(transaction_id, attempt = 1)
    transaction = Transaction.find(transaction_id)

    # Only poll transactions that are waiting for confirmation
    return unless transaction.crypto_sent?
    return unless transaction.blockchain_tx_hash.present?

    rpc_url = ENV['BASE_RPC_URL'].presence || "https://mainnet.base.org"
    receipt  = fetch_receipt(rpc_url, transaction.blockchain_tx_hash)

    if receipt.nil?
      # Transaction still pending — retry unless we've hit the limit
      if attempt >= MAX_ATTEMPTS
        transaction.update!(
          status: :failed,
          failure_reason: "Blockchain confirmation timed out after #{MAX_ATTEMPTS} attempts. TX: #{transaction.blockchain_tx_hash}"
        )
        notify_transaction_email(:failed, transaction)
        NotificationService.transaction_failed(transaction)
        Rails.logger.warn "Zèllus: TX ##{transaction_id} confirmation timed out (#{MAX_ATTEMPTS} attempts)"
      else
        Rails.logger.info "Zèllus: TX ##{transaction_id} still pending (attempt #{attempt}/#{MAX_ATTEMPTS}), retrying in 15s"
        TransactionConfirmationWorker.perform_in(15.seconds, transaction_id, attempt + 1)
      end

    elsif receipt["status"] == "0x1"
      # Confirmed successfully
      transaction.completed!
      notify_transaction_email(:completed, transaction)
      NotificationService.transaction_completed(transaction)
      Rails.logger.info "Zèllus: TX ##{transaction_id} confirmed on-chain! Hash: #{transaction.blockchain_tx_hash}"

    else
      # Receipt exists but status = 0x0 means the tx was reverted on-chain
      transaction.update!(
        status: :failed,
        failure_reason: "Blockchain transaction reverted on-chain. TX: #{transaction.blockchain_tx_hash}"
      )
      notify_transaction_email(:failed, transaction)
      NotificationService.transaction_failed(transaction)
      Rails.logger.error "Zèllus: TX ##{transaction_id} reverted on-chain. Hash: #{transaction.blockchain_tx_hash}"
    end

  rescue => e
    Rails.logger.error "Zèllus ConfirmationWorker error [tx=#{transaction_id}]: #{e.message}"
    # Don't raise — we don't want Sidekiq to retry with its own backoff,
    # we manage our own retry schedule above
  end

  private

  def fetch_receipt(rpc_url, tx_hash)
    conn = Faraday.new(url: rpc_url)
    response = conn.post do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = {
        jsonrpc: "2.0",
        id:      1,
        method:  "eth_getTransactionReceipt",
        params:  [tx_hash]
      }.to_json
    end

    body = JSON.parse(response.body)
    body["result"]  # nil if pending, hash with "status" if confirmed
  rescue => e
    Rails.logger.error "Zèllus: eth_getTransactionReceipt failed: #{e.message}"
    nil
  end

  def notify_transaction_email(kind, transaction)
    TransactionMailer.with(transaction_id: transaction.id).public_send(kind).deliver_now
  rescue => e
    Rails.logger.error "Transaction #{kind} email failed [tx=#{transaction.id}]: #{e.message}"
  end
end

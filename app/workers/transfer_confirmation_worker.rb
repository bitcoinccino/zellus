# frozen_string_literal: true

require "sidekiq"
require "faraday"

class TransferConfirmationWorker
  include Sidekiq::Job

  # Poll every 15 seconds, give up after 20 attempts (~5 minutes)
  MAX_ATTEMPTS = 20

  def perform(transfer_id, attempt = 1)
    transfer = Transfer.find(transfer_id)

    # Only poll transfers that are waiting for blockchain confirmation
    return unless transfer.sent?
    return unless transfer.blockchain_tx_hash.present?

    rpc_url = ENV["BASE_RPC_URL"].presence || "https://mainnet.base.org"
    receipt = fetch_receipt(rpc_url, transfer.blockchain_tx_hash)

    if receipt.nil?
      # Transaction still pending — retry unless we've hit the limit
      if attempt >= MAX_ATTEMPTS
        transfer.update!(
          status: :failed,
          failure_reason: "Konfirmasyon blockchain ekspire apre #{MAX_ATTEMPTS} esè. TX: #{transfer.blockchain_tx_hash}"
        )
        refund_wallet_if_needed!(transfer)
        notify_sender_failed(transfer)
        Rails.logger.warn "TransferConfirmation: transfer=#{transfer_id} timed out (#{MAX_ATTEMPTS} attempts)"
      else
        Rails.logger.info "TransferConfirmation: transfer=#{transfer_id} still pending (attempt #{attempt}/#{MAX_ATTEMPTS}), retrying in 15s"
        TransferConfirmationWorker.perform_in(15.seconds, transfer_id, attempt + 1)
      end

    elsif receipt["status"] == "0x1"
      # Confirmed successfully on-chain
      transfer.update!(status: :completed, completed_at: Time.current)
      notify_sender_completed(transfer)
      Rails.logger.info "TransferConfirmation: transfer=#{transfer_id} confirmed on-chain! Hash: #{transfer.blockchain_tx_hash}"

    else
      # Receipt exists but status = 0x0 means the tx was reverted
      transfer.update!(
        status: :failed,
        failure_reason: "Tranzaksyon blockchain te rejte. TX: #{transfer.blockchain_tx_hash}"
      )
      refund_wallet_if_needed!(transfer)
      notify_sender_failed(transfer)
      Rails.logger.error "TransferConfirmation: transfer=#{transfer_id} reverted on-chain. Hash: #{transfer.blockchain_tx_hash}"
    end

  rescue => e
    Rails.logger.error "TransferConfirmation error [transfer=#{transfer_id}]: #{e.message}"
    # Don't raise — we manage our own retry schedule above
  end

  private

  def fetch_receipt(rpc_url, tx_hash)
    conn = Faraday.new(url: rpc_url)
    response = conn.post do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = {
        jsonrpc: "2.0",
        id:      1,
        method:  "eth_getTransactionReceipt",
        params:  [ tx_hash ]
      }.to_json
    end

    body = JSON.parse(response.body)
    body["result"]
  rescue => e
    Rails.logger.error "TransferConfirmation: eth_getTransactionReceipt failed: #{e.message}"
    nil
  end

  # ── Refund wallet if transfer was wallet-funded ──
  def refund_wallet_if_needed!(transfer)
    return unless transfer.wallet_funded?

    sender_wallet = transfer.user.wallet
    return unless sender_wallet

    if transfer.usd_wallet_transfer? || transfer.usd_address_transfer?
      usd_amount = transfer.crypto_amount || transfer.net_amount
      WalletService.new(sender_wallet).refund!(
        amount: usd_amount,
        asset: "usd",
        reference: transfer,
        reason: "Tranzaksyon blockchain echwe — ranbousman otomatik"
      )
      Rails.logger.info "TransferConfirmation: refunded #{usd_amount} USD to sender wallet [transfer=#{transfer.id}]"
    elsif transfer.htg_transfer?
      WalletService.new(sender_wallet).refund!(
        amount: transfer.amount,
        reference: transfer,
        reason: "Tranzaksyon blockchain echwe — ranbousman otomatik"
      )
      Rails.logger.info "TransferConfirmation: refunded #{transfer.amount} HTG to sender wallet [transfer=#{transfer.id}]"
    end
  rescue => e
    Rails.logger.error "TransferConfirmation: wallet refund failed [transfer=#{transfer.id}]: #{e.message}"
  end

  def notify_sender_completed(transfer)
    TransferMailer.with(transfer_id: transfer.id).sender_completed.deliver_later
  rescue => e
    Rails.logger.error "Transfer sender_completed email failed [transfer=#{transfer.id}]: #{e.message}"
  end

  def notify_sender_failed(transfer)
    TransferMailer.with(transfer_id: transfer.id).sender_failed.deliver_later
  rescue => e
    Rails.logger.error "Transfer sender_failed email failed [transfer=#{transfer.id}]: #{e.message}"
  end
end

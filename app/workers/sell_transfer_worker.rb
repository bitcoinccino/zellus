# frozen_string_literal: true
require 'sidekiq'
require 'faraday'

class SellTransferWorker
  include Sidekiq::Job

  MAX_ATTEMPTS = 20

  def perform(transaction_id, attempt = 1)
    transaction = Transaction.find(transaction_id)

    return unless transaction.crypto_sent?
    return unless transaction.sell? || transaction.loan_request?

    if transaction.loan_request?
      # 1. Standard Payout for New Loans
      process_moncash_payout(transaction)
    elsif transaction.sell? && transaction.failure_reason&.include?("REPAYMENT_LOAN_")
      # 2. USDC REPAYMENT: Verify deposit then settle debt (No MonCash Payout)
      process_usdc_repayment(transaction, transaction_id, attempt)
    else
      # 3. Standard Sell: Verify USDC then Payout MonCash
      process_sell_with_blockchain_check(transaction, transaction_id, attempt)
    end

  rescue => e
    Rails.logger.error "Zèllus Bank Payout Error [tx=#{transaction_id}]: #{e.message}"
  end

  private

  # NEW: Handles settling debt when USDC is received
  def process_usdc_repayment(transaction, transaction_id, attempt)
    return unless transaction.blockchain_tx_hash.present?

    rpc_url = ENV['BASE_RPC_URL'].presence || "https://mainnet.base.org"
    receipt = fetch_receipt(rpc_url, transaction.blockchain_tx_hash)

    if receipt.nil?
      attempt >= MAX_ATTEMPTS ? fail_tx(transaction, "USDC timeout") : retry_job(transaction_id, attempt)
    elsif receipt["status"] == "0x1"
      # SETTLE DEBT
      loan_id = transaction.failure_reason.split("_").last
      original_loan = Transaction.find_by(id: loan_id)

      if original_loan
        original_loan.update!(status: :completed)
        transaction.update!(status: :completed, failure_reason: "Debt Settled via USDC")
        
        # FOKON BOOST: Reward for using Sovereign Assets (+60 points)
        transaction.user.increment!(:credit_score, 60)
        notify_transaction_email(:completed, transaction)
        NotificationService.transaction_completed(transaction)
        Rails.logger.info "Zèllus: Loan ##{loan_id} repaid via USDC. User score boosted."
      end
    else
      fail_tx(transaction, "USDC transaction reverted.")
    end
  end

  def process_sell_with_blockchain_check(transaction, transaction_id, attempt)
    return unless transaction.blockchain_tx_hash.present?

    rpc_url = ENV['BASE_RPC_URL'].presence || "https://mainnet.base.org"
    receipt = fetch_receipt(rpc_url, transaction.blockchain_tx_hash)

    if receipt.nil?
      attempt >= MAX_ATTEMPTS ? fail_tx(transaction, "USDC timeout") : retry_job(transaction_id, attempt)
    elsif receipt["status"] == "0x1"
      process_moncash_payout(transaction)
    else
      fail_tx(transaction, "USDC transaction reverted.")
    end
  end

  def process_moncash_payout(transaction)
    type_label = transaction.loan_request? ? "Loan" : "Sell"
    payout_reference = "zellus-#{transaction.transaction_type}-#{transaction.id}"

    # Verify MonCash Receiver
    customer_check = MoncashService.customer_status(transaction.moncash_phone)
    unless customer_check[:success] && customer_check[:active]
      transaction.update!(status: :payout_failed, failure_reason: "MonCash Check: Account inactive")
      return
    end

    # Trigger Payout
    result = MoncashService.transfert(transaction.moncash_phone, transaction.fiat_amount.to_i, payout_reference)

    if result[:success]
      transaction.update!(status: :completed, moncash_transaction_id: result[:transaction_id])
      notify_transaction_email(:completed, transaction)
      NotificationService.transaction_completed(transaction)
    else
      # Ambiguous error check
      status_check = MoncashService.prefunded_transaction_status(payout_reference)
      if status_check[:success]
        transaction.update!(status: :completed)
        notify_transaction_email(:completed, transaction)
        NotificationService.transaction_completed(transaction)
      else
        transaction.update!(status: :payout_failed, failure_reason: "MonCash failed: #{result[:error]}")
      end
    end
  end

  def retry_job(tx_id, attempt)
    SellTransferWorker.perform_in(15.seconds, tx_id, attempt + 1)
  end

  def fail_tx(transaction, reason)
    transaction.update!(status: :failed, failure_reason: reason)
    notify_transaction_email(:failed, transaction)
    NotificationService.transaction_failed(transaction)
  end

  def fetch_receipt(rpc_url, tx_hash)
    conn = Faraday.new(url: rpc_url)
    response = conn.post do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = { jsonrpc: "2.0", id: 1, method: "eth_getTransactionReceipt", params: [tx_hash] }.to_json
    end
    JSON.parse(response.body)["result"]
  rescue => e
    nil
  end

  def notify_transaction_email(kind, transaction)
    TransactionMailer.with(transaction_id: transaction.id).public_send(kind).deliver_now
  rescue => e
    Rails.logger.error "Email failed [tx=#{transaction.id}]: #{e.message}"
  end
end

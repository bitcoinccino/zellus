# frozen_string_literal: true

# Handles inbound Circle webhook events (transaction state changes).
#
# Circle signs every webhook payload with HMAC-SHA256 using the
# CIRCLE_WEBHOOK_SECRET.  We verify the signature before processing.
#
# Key events:
#   transactions.complete → credit the user's wallet via WalletService.deposit!
#   transactions.failed   → log + notify admin (refund handled by worker retry)
#
module Api
  class CircleWebhooksController < ActionController::API
    before_action :verify_circle_signature

    def create
      event_type = params.dig(:type) || params.dig(:notificationType)
      data       = params.dig(:data) || params.except(:controller, :action, :type, :notificationType)

      Rails.logger.info "CircleWebhook: received event_type=#{event_type}"

      case event_type
      when "transactions.complete"
        handle_transaction_complete(data)
      when "transactions.failed"
        handle_transaction_failed(data)
      else
        Rails.logger.info "CircleWebhook: ignoring event_type=#{event_type}"
      end

      head :ok
    rescue => e
      Rails.logger.error "CircleWebhook: error processing webhook: #{e.message}"
      head :ok # Always return 200 to avoid Circle retries
    end

    private

    # ── Signature verification ───────────────────────────────────────

    def verify_circle_signature
      secret = CircleConfig::WEBHOOK_SECRET
      return if secret.blank? || secret == "placeholder" # skip in dev if not configured

      payload   = request.raw_post
      signature = request.headers["X-Circle-Signature"] ||
                  request.headers["HTTP_X_CIRCLE_SIGNATURE"]

      unless signature.present?
        Rails.logger.warn "CircleWebhook: missing signature header"
        return head :unauthorized
      end

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, payload)

      unless ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
        Rails.logger.warn "CircleWebhook: invalid signature"
        return head :unauthorized
      end
    end

    # ── Event handlers ───────────────────────────────────────────────

    def handle_transaction_complete(data)
      tx = data.is_a?(Hash) ? data : (data.respond_to?(:to_unsafe_h) ? data.to_unsafe_h : {})

      transfer_id   = tx["id"]
      wallet_id     = tx.dig("destinationWalletId") || tx.dig("walletId")
      source_addr   = tx.dig("sourceAddress")
      amounts       = tx.dig("amounts") || []
      amount_str    = amounts.first || tx.dig("amount", "amount") || "0"
      amount        = BigDecimal(amount_str.to_s)

      # Only process inbound deposits (not outbound sends we initiated)
      direction = tx.dig("transactionType") || tx.dig("direction")
      if direction == "OUTBOUND"
        Rails.logger.info "CircleWebhook: skipping outbound tx #{transfer_id}"
        return
      end

      user = User.find_by(circle_wallet_id: wallet_id)
      unless user
        Rails.logger.warn "CircleWebhook: no user for wallet_id=#{wallet_id} (tx #{transfer_id})"
        return
      end

      # Idempotency: skip if already credited
      if WalletLedgerEntry.exists?(circle_transfer_id: transfer_id)
        Rails.logger.info "CircleWebhook: already processed transfer_id=#{transfer_id}"
        return
      end

      svc = WalletService.new(user.wallet)
      svc.deposit!(
        amount:      amount,
        asset:       "usd",
        description: "Depo USD via Circle (#{source_addr.to_s.first(10)}…)"
      )

      # Tag the ledger entry with the Circle transfer ID for reconciliation
      entry = user.wallet.wallet_ledger_entries.order(created_at: :desc).first
      entry&.update_column(:circle_transfer_id, transfer_id)

      Rails.logger.info "CircleWebhook: deposited #{amount} USD for user #{user.id} (tx #{transfer_id})"

      # ── In-app notification + email (matches UsdDepositMonitorWorker pattern) ──
      begin
        NotificationService.crypto_deposit_received(user, amount, "usd", transfer_id)
      rescue => e
        Rails.logger.error "CircleWebhook: notification failed for user=#{user.id}: #{e.message}"
      end

      begin
        WalletMailer.with(user_id: user.id, amount: amount.to_f, asset: "usd", tx_hash: transfer_id)
                    .deposit_confirmed.deliver_later
      rescue => e
        Rails.logger.error "CircleWebhook: email failed for user=#{user.id}: #{e.message}"
      end
    end

    def handle_transaction_failed(data)
      tx          = data.is_a?(Hash) ? data : (data.respond_to?(:to_unsafe_h) ? data.to_unsafe_h : {})
      transfer_id = tx["id"]
      error_msg   = tx.dig("errorReason") || tx.dig("error", "message") || "unknown"

      Rails.logger.error "CircleWebhook: transaction FAILED id=#{transfer_id} reason=#{error_msg}"

      # TODO: notify admin, trigger refund flow if this was an outbound transfer
    end
  end
end

# frozen_string_literal: true

# Handles inbound Lightspark Grid webhook events (UMA payments).
#
# Lightspark signs every webhook payload with HMAC-SHA256 using the
# LIGHTSPARK_WEBHOOK_SECRET.  We verify the signature before processing.
#
# On INCOMING_PAYMENT COMPLETED:
#   1. Look up user by cashtag from the UMA address
#   2. Convert received USD to HTG via RateService.sell_rate (FX spread = revenue)
#   3. Deduct remittance fee via FeeService.remittance_fee (1.5%, min 15 HTG)
#   4. Credit user's wallet via WalletService.deposit!
#   5. Tag ledger entry with lightspark_payment_id (idempotency)
#   6. Send notification
#
class LightsparkWebhooksController < ActionController::API
  before_action :verify_lightspark_signature

  def create
    event_type = params.dig(:event_type) || params.dig(:type)
    data       = params.dig(:data) || params.except(:controller, :action, :event_type, :type)

    Rails.logger.info "LightsparkWebhook: received event_type=#{event_type}"

    case event_type
    when "INCOMING_PAYMENT_COMPLETED", "incoming_payment.completed"
      handle_incoming_payment(data)
    else
      Rails.logger.info "LightsparkWebhook: ignoring event_type=#{event_type}"
    end

    head :ok
  rescue => e
    Rails.logger.error "LightsparkWebhook: error processing webhook: #{e.message}"
    head :ok # Always return 200 to avoid retries
  end

  private

  # ── Signature verification ───────────────────────────────────────

  def verify_lightspark_signature
    secret = LightsparkConfig::LIGHTSPARK_WEBHOOK_SECRET
    return if secret.blank? # skip in dev if not configured

    payload   = request.raw_post
    signature = request.headers["X-Lightspark-Signature"] ||
                request.headers["HTTP_X_LIGHTSPARK_SIGNATURE"]

    unless signature.present?
      Rails.logger.warn "LightsparkWebhook: missing signature header"
      return head :unauthorized
    end

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, payload)

    unless ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
      Rails.logger.warn "LightsparkWebhook: invalid signature"
      head :unauthorized
    end
  end

  # ── Event handler ────────────────────────────────────────────────

  def handle_incoming_payment(data)
    tx = data.is_a?(Hash) ? data : (data.respond_to?(:to_unsafe_h) ? data.to_unsafe_h : {})

    payment_id  = tx["id"] || tx["payment_id"]
    uma_address = tx["receiver_uma_address"] || tx["receiver_uma"] || ""
    sender_uma  = tx["sender_uma_address"] || tx["sender_uma"] || ""
    amount_str  = tx["amount"] || tx.dig("receiving_amount") || "0"
    currency    = (tx["currency"] || tx["receiving_currency"] || "USD").upcase
    amount      = BigDecimal(amount_str.to_s)

    # Idempotency: skip if already processed
    if payment_id.present? && WalletLedgerEntry.exists?(lightspark_payment_id: payment_id)
      Rails.logger.info "LightsparkWebhook: already processed payment_id=#{payment_id}"
      return
    end

    # Look up user by cashtag from UMA address ($cashtag@zellus.ht)
    cashtag = extract_cashtag(uma_address)
    user = User.find_by("LOWER(cashtag) = ?", cashtag.downcase) if cashtag.present?

    unless user
      Rails.logger.warn "LightsparkWebhook: no user for UMA address=#{uma_address} (payment #{payment_id})"
      return
    end

    unless user.uma_enabled?
      Rails.logger.warn "LightsparkWebhook: UMA disabled for user=#{user.id} (payment #{payment_id})"
      return
    end

    # Determine deposit asset and amount
    # If received in USD, convert to HTG using sell_rate (includes FX spread = revenue)
    if currency == "USD" && user.prefers_htg_payout?
      htg_amount = (amount * RateService.sell_rate.to_d).round(2)
      fee        = FeeService.remittance_fee(htg_amount)
      net_htg    = htg_amount - fee
      deposit_asset  = "htg"
      deposit_amount = net_htg
      description    = "UMA remitans #{format('%.2f', amount)} USD → #{net_htg.to_i} HTG (de #{sender_uma.presence || 'UMA'})"
    else
      # Deposit as USD (no HTG conversion)
      fee_htg        = FeeService.remittance_fee((amount * RateService.sell_rate.to_d).round(2))
      fee_usd        = (fee_htg / RateService.sell_rate.to_d).round(6)
      deposit_asset  = "usd"
      deposit_amount = amount - fee_usd
      description    = "UMA remitans #{format('%.2f', amount)} USD (de #{sender_uma.presence || 'UMA'})"
    end

    if deposit_amount <= 0
      Rails.logger.warn "LightsparkWebhook: deposit_amount <= 0 after fees for payment_id=#{payment_id}"
      return
    end

    # Credit wallet
    user.ensure_wallet!
    svc = WalletService.new(user.wallet)
    svc.deposit!(
      amount:      deposit_amount,
      asset:       deposit_asset,
      description: description,
      skip_limits: true
    )

    # Tag ledger entry with lightspark_payment_id for idempotency + reconciliation
    entry = user.wallet.wallet_ledger_entries.order(created_at: :desc).first
    entry&.update_column(:lightspark_payment_id, payment_id)

    Rails.logger.info "LightsparkWebhook: deposited #{deposit_amount} #{deposit_asset} for user #{user.id} (payment #{payment_id})"

    # Notification
    NotificationService.uma_payment_received(user, deposit_amount, deposit_asset, sender_uma)
  rescue => e
    Rails.logger.error "LightsparkWebhook: failed to process payment #{data&.dig('id')}: #{e.message}"
  end

  def extract_cashtag(uma_address)
    # UMA address format: cashtag@domain or $cashtag@domain
    return nil if uma_address.blank?
    uma_address.to_s.delete_prefix("$").split("@").first
  end
end

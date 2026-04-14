class BonidConsentWebhooksController < ActionController::Base
  skip_forgery_protection

  def create
    consent_token = params[:consent_token]
    event_status  = params[:status] # "approved", "denied", "expired"

    consent = BonidConsentRequest.find_by(consent_token: consent_token)
    unless consent
      render json: { error: "Consent not found" }, status: :not_found
      return
    end

    transfer = consent.transfer

    case event_status
    when "approved"
      consent.update!(
        status: :approved,
        signature: params[:signature],
        decided_at: params[:decided_at],
        biometric_verification: params[:biometric_verification]&.to_unsafe_h
      )

      if transfer.awaiting_consent?
        # Consent approved — move back to pending for PIN review.
        # If wallet was already debited (old flow), go straight to funded + payout.
        if transfer.funded_at.present?
          # Old flow: wallet already debited → trigger payout
          transfer.update!(status: :funded)
          TransferPayoutWorker.perform_async(transfer.id)
          NotificationService.deposit_confirmed(transfer.user, transfer.amount)
          Rails.logger.info "BonID consent approved for transfer #{transfer.token} — payout triggered (wallet already debited)"
        else
          # New flow: consent before review → move to pending for PIN confirmation
          transfer.update!(status: :pending)
          Rails.logger.info "BonID consent approved for transfer #{transfer.token} — awaiting PIN confirmation"
        end

        # Notify user that consent was approved (real-time push)
        NotificationChannel.broadcast_to(transfer.user, {
          type: "bonid_consent_approved",
          transfer_token: transfer.token,
          message: "Konsentisyon BonID apwouve! Ou ka konfime transfè a kounye a."
        })
      end

    when "denied"
      consent.update!(status: :denied, decided_at: params[:decided_at])

      if transfer.awaiting_consent?
        transfer.update!(status: :failed, failure_reason: "Sitwayen refize konsentisyon BonID")

        # Only refund if wallet was already debited (old flow where consent was after PIN)
        refund_held_funds(transfer, "Konsentisyon BonID refize") if transfer.funded_at.present?

        NotificationService.transfer_failed(transfer)
        Rails.logger.info "BonID consent denied for transfer #{transfer.token}"
      end

    when "expired"
      consent.update!(status: :expired)

      if transfer.awaiting_consent?
        transfer.update!(status: :failed, failure_reason: "Konsentisyon BonID ekspire")

        # Only refund if wallet was already debited (old flow where consent was after PIN)
        refund_held_funds(transfer, "Konsentisyon BonID ekspire") if transfer.funded_at.present?

        NotificationService.transfer_failed(transfer)
        Rails.logger.info "BonID consent expired for transfer #{transfer.token}"
      end
    end

    head :ok
  rescue => e
    Rails.logger.error "BonID consent webhook error: #{e.message}"
    head :internal_server_error
  end

  private

  # Refund held funds to the correct asset wallet.
  # MonCash-funded transfers cannot be auto-refunded (requires manual admin action).
  def refund_held_funds(transfer, reason)
    if transfer.funding_source == "moncash"
      Rails.logger.warn "MonCash-funded transfer #{transfer.token} denied/expired — requires manual admin refund"
      return
    end

    wallet = transfer.user.wallet
    return unless wallet

    if transfer.usd_wallet_transfer? || transfer.usd_address_transfer?
      refund_amount = transfer.crypto_amount || transfer.net_amount
      refund_asset = "usd"
      label = "#{refund_amount} USD"
    elsif transfer.stock_wallet_transfer?
      refund_amount = transfer.crypto_amount || transfer.net_amount
      refund_asset = transfer.asset.to_s
      label = "#{refund_amount} #{refund_asset.upcase}"
    else
      refund_amount = transfer.amount
      refund_asset = "htg"
      label = "#{transfer.amount.to_i} HTG"
    end

    WalletService.new(wallet).refund!(
      amount: refund_amount,
      asset: refund_asset,
      reference: transfer,
      reason: "#{reason} — ranbouse #{label}"
    )
  end
end

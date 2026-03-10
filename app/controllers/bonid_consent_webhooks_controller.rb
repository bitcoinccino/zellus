class BonidConsentWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :require_cashtag!

  # Skip authentication — this is called by BonID server
  skip_before_action :authenticate_user! if method_defined?(:authenticate_user!)

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
        decided_at: params[:decided_at]
      )

      if transfer.awaiting_consent?
        # Resume the transfer: move to funded and trigger payout
        transfer.update!(status: :funded, funded_at: Time.current)
        TransferPayoutWorker.perform_async(transfer.id)

        # Notify user that consent was approved
        NotificationService.deposit_confirmed(transfer.user, transfer.amount)

        Rails.logger.info "BonID consent approved for transfer #{transfer.token} — payout triggered"
      end

    when "denied"
      consent.update!(status: :denied, decided_at: params[:decided_at])

      if transfer.awaiting_consent?
        transfer.update!(status: :failed, failure_reason: "Sitwayen refize konsentisyon BonID")

        # Refund the held funds
        wallet = transfer.user.wallet
        if wallet
          WalletService.new(wallet).refund!(
            amount: transfer.amount,
            reason: "Konsentisyon BonID refize — ranbouse #{transfer.amount.to_i} HTG"
          )
        end

        NotificationService.transfer_failed(transfer)
        Rails.logger.info "BonID consent denied for transfer #{transfer.token} — refunded"
      end

    when "expired"
      consent.update!(status: :expired)

      if transfer.awaiting_consent?
        transfer.update!(status: :failed, failure_reason: "Konsentisyon BonID ekspire")

        wallet = transfer.user.wallet
        if wallet
          WalletService.new(wallet).refund!(
            amount: transfer.amount,
            reason: "Konsentisyon BonID ekspire — ranbouse #{transfer.amount.to_i} HTG"
          )
        end

        NotificationService.transfer_failed(transfer)
        Rails.logger.info "BonID consent expired for transfer #{transfer.token} — refunded"
      end
    end

    head :ok
  rescue => e
    Rails.logger.error "BonID consent webhook error: #{e.message}"
    head :internal_server_error
  end
end

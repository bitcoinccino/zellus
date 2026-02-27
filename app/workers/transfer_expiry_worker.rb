# frozen_string_literal: true
require 'sidekiq'

class TransferExpiryWorker
  include Sidekiq::Job

  def perform(transfer_id)
    transfer = Transfer.find(transfer_id)

    # Only expire funded transfers that passed their deadline
    return unless transfer.funded? && transfer.expired_now?

    transfer.update!(status: :expired)
    Rails.logger.info "TransferExpiry: transfer=#{transfer_id} expired (unclaimed after 72h)"

    # Notify sender that transfer expired and will be refunded
    begin
      TransferMailer.with(transfer_id: transfer.id).sender_expired.deliver_later
    rescue => e
      Rails.logger.error "Transfer expiry email failed [transfer=#{transfer_id}]: #{e.message}"
    end

    # TODO: Auto-refund via MonCash when refund API is available
    # For now, flag for manual refund by admin
    Rails.logger.info "TransferExpiry: transfer=#{transfer_id} flagged for manual refund of #{transfer.amount} HTG"

  rescue => e
    Rails.logger.error "TransferExpiry error [transfer=#{transfer_id}]: #{e.message}"
  end
end

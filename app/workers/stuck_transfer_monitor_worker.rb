# frozen_string_literal: true
require 'sidekiq'

class StuckTransferMonitorWorker
  include Sidekiq::Job

  # How long a transfer can stay "funded" before we consider it stuck
  STUCK_THRESHOLD = 3.minutes

  # How often this monitor re-checks
  POLL_INTERVAL = 5.minutes

  def perform
    stuck_transfers = Transfer
      .where(status: :funded)
      .where("funded_at < ?", STUCK_THRESHOLD.ago)
      .where.not(status: [:completed, :failed, :expired, :refunded])

    stuck_transfers.find_each do |transfer|
      Rails.logger.warn "StuckTransferMonitor: transfer=#{transfer.id} (token=#{transfer.token}) stuck at 'funded' since #{transfer.funded_at} — re-triggering payout"

      begin
        TransferPayoutWorker.perform_async(transfer.id)
      rescue => e
        Rails.logger.error "StuckTransferMonitor: failed to re-enqueue transfer=#{transfer.id}: #{e.message}"
      end
    end

    if stuck_transfers.any?
      Rails.logger.warn "StuckTransferMonitor: re-triggered #{stuck_transfers.count} stuck transfer(s)"
    end

  rescue => e
    Rails.logger.error "StuckTransferMonitor error: #{e.message}"
  ensure
    # Re-schedule self for next run
    self.class.perform_in(POLL_INTERVAL)
  end
end

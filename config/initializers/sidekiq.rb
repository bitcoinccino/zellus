# frozen_string_literal: true

# Schedule recurring Sidekiq workers on server startup.
# Each monitor re-enqueues itself after each run,
# so we only need to kick them off once on startup.
# We check for existing scheduled/queued jobs to prevent duplicates on restart.

if defined?(Sidekiq)
  Sidekiq.configure_server do |config|
    config.on(:startup) do
      require 'sidekiq/api'

      # Helper: only schedule if no existing job for this worker class
      schedule_unique = ->(klass, delay) do
        already_exists = Sidekiq::ScheduledSet.new.any? { |j| j.klass == klass.name } ||
                         Sidekiq::Queue.new.any? { |j| j.klass == klass.name }
        if already_exists
          Rails.logger.info "Sidekiq: #{klass.name} already scheduled, skipping"
        else
          Rails.logger.info "Sidekiq: scheduling #{klass.name} in #{delay}s"
          klass.perform_in(delay.seconds)
        end
      end

      # Stuck transfer safety net — always runs (no treasury key needed)
      schedule_unique.call(StuckTransferMonitorWorker, 15)

      # Stuck withdrawal safety net — auto-refunds wallet debits with no MonCash TX
      schedule_unique.call(StuckWithdrawalMonitorWorker, 25)

      # Platform reserve alert — emails admin when USDC/HTG reserves run low
      schedule_unique.call(ReserveAlertWorker, 60)

      # Crypto deposit monitors — require treasury key
      if ENV['TREASURY_PRIVATE_KEY'].present?
        schedule_unique.call(UsdDepositMonitorWorker, 10)
        schedule_unique.call(EthDepositMonitorWorker, 20)
        schedule_unique.call(WbtcDepositMonitorWorker, 30)
      end
    end
  end
end

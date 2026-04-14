# frozen_string_literal: true

require "sidekiq"

# One-time (or re-runnable) job to provision Circle wallets for all
# existing users who don't have one yet.
#
# Run manually:  CircleWalletBackfillWorker.perform_async
#
# Respects Circle rate limits by processing in batches with a small
# delay between API calls.
#
class CircleWalletBackfillWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: "low"

  BATCH_SIZE = 50
  DELAY_BETWEEN_CALLS = 0.25 # seconds — ~4 wallets/sec

  def perform(offset = 0)
    unless CryptoProvider.circle?
      Rails.logger.info "CircleWalletBackfill: CRYPTO_PROVIDER is not circle, skipping"
      return
    end

    users = User.where(circle_wallet_id: nil)
                .order(:id)
                .offset(offset)
                .limit(BATCH_SIZE)

    if users.empty?
      Rails.logger.info "CircleWalletBackfill: complete — all users provisioned"
      return
    end

    provisioned = 0
    failed      = 0

    users.each do |user|
      begin
        user.create_circle_wallet!
        provisioned += 1
        sleep(DELAY_BETWEEN_CALLS)
      rescue => e
        failed += 1
        Rails.logger.error "CircleWalletBackfill: user=#{user.id} failed: #{e.message}"
      end
    end

    Rails.logger.info "CircleWalletBackfill: batch offset=#{offset} — provisioned=#{provisioned}, failed=#{failed}"

    # Queue next batch
    if users.size == BATCH_SIZE
      CircleWalletBackfillWorker.perform_async(offset + BATCH_SIZE)
    else
      Rails.logger.info "CircleWalletBackfill: all batches queued, done"
    end
  end
end

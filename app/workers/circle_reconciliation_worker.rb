# frozen_string_literal: true

require "sidekiq"

# Hourly reconciliation: compares Circle on-chain wallet balances with
# the local WalletService ledger.  Logs mismatches > $0.01 for admin review.
#
# Skips users with recent pending/sent transfers (last 10 min) since
# Circle may show locked/pending balance that hasn't settled via webhook yet.
#
# Schedule via sidekiq-cron:
#   CircleReconciliationWorker.perform_async
#
class CircleReconciliationWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: "low"

  MISMATCH_THRESHOLD = BigDecimal("0.01") # USD
  PENDING_WINDOW     = 10.minutes

  def perform
    unless CryptoProvider.circle?
      Rails.logger.info "CircleReconciliation: CRYPTO_PROVIDER is not circle, skipping"
      return
    end

    mismatches = 0
    checked    = 0

    users_to_check.find_each do |user|
      checked += 1
      circle_balance = CircleService.wallet_balance(user.circle_wallet_id)
      local_balance  = user.wallet&.usd_balance || BigDecimal("0")

      diff = (circle_balance - local_balance).abs

      if diff > MISMATCH_THRESHOLD
        mismatches += 1
        Rails.logger.warn(
          "CircleReconciliation: MISMATCH user=#{user.id} " \
          "circle=#{circle_balance} local=#{local_balance} diff=#{diff}"
        )
      end
    rescue CircleService::CircleError => e
      Rails.logger.error "CircleReconciliation: API error for user=#{user.id}: #{e.message}"
    rescue => e
      Rails.logger.error "CircleReconciliation: unexpected error for user=#{user.id}: #{e.message}"
    end

    Rails.logger.info "CircleReconciliation: checked=#{checked} mismatches=#{mismatches}"
  end

  private

  # Users with Circle wallets, excluding those with recent pending transfers
  # (balance may not have settled yet).
  def users_to_check
    recent_pending_user_ids = Transfer
      .where(status: %w[sent pending])
      .where("updated_at > ?", PENDING_WINDOW.ago)
      .select(:user_id)

    User
      .where.not(circle_wallet_id: nil)
      .where.not(id: recent_pending_user_ids)
      .includes(:wallet)
  end
end

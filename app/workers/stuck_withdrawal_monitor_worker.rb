# frozen_string_literal: true
require 'sidekiq'

# Detects withdrawal entries that were debited from a wallet but never
# completed (no moncash_transaction_id) — typically because Sidekiq
# wasn't running when WalletWithdrawWorker was queued.
#
# After STUCK_THRESHOLD, the withdrawal is auto-refunded to the wallet
# and the user is notified.
class StuckWithdrawalMonitorWorker
  include Sidekiq::Job

  # How long a withdrawal can sit without a MonCash TX before we refund
  STUCK_THRESHOLD = 10.minutes

  # How often this monitor re-checks
  POLL_INTERVAL = 5.minutes

  def perform
    stuck_entries = WalletLedgerEntry
      .where(entry_type: "withdrawal", asset: "htg", moncash_transaction_id: nil)
      .where("description LIKE ?", "%MonCash%")
      .where("created_at < ?", STUCK_THRESHOLD.ago)
      .where("created_at > ?", 24.hours.ago) # don't process ancient entries
      .order(created_at: :desc)

    stuck_entries.find_each do |entry|
      Rails.logger.warn "StuckWithdrawalMonitor: entry=#{entry.id} stuck since #{entry.created_at} — auto-refunding #{entry.amount} HTG to user=#{entry.user_id}"

      ActiveRecord::Base.transaction do
        wallet = entry.user.wallet
        next unless wallet

        # Refund the payout amount
        new_balance = wallet.htg_balance + entry.amount
        wallet.wallet_ledger_entries.create!(
          user: entry.user,
          entry_type: "refund",
          asset: "htg",
          amount: entry.amount,
          balance_after: new_balance,
          description: "Retrè a pa t reyisi, lajan retounen nan bous"
        )
        wallet.update!(htg_balance: new_balance)

        # Also refund any associated fee
        fee_entry = wallet.wallet_ledger_entries
          .where(entry_type: ["instant_fee", "fee"])
          .where("created_at >= ? AND created_at <= ?", entry.created_at - 5.seconds, entry.created_at + 5.seconds)
          .first
        if fee_entry
          new_balance += fee_entry.amount
          wallet.wallet_ledger_entries.create!(
            user: entry.user,
            entry_type: "refund",
            asset: "htg",
            amount: fee_entry.amount,
            balance_after: new_balance,
            description: "Ranbouse frè retrè"
          )
          wallet.update!(htg_balance: new_balance)
        end

        # Mark the original entry so we don't process it again
        entry.update_column(:moncash_transaction_id, "REFUNDED-#{entry.id}")
      end

      # Notify the user
      begin
        NotificationService.withdrawal_failed(entry.user, entry.amount, "Sistèm pa t ka voye lajan an — ranbouse otomatik")
      rescue => e
        Rails.logger.error "StuckWithdrawalMonitor: notification failed for entry=#{entry.id}: #{e.message}"
      end
    end

    # Reschedule
    self.class.perform_in(POLL_INTERVAL)
  end
end

class BackfillTokensForExistingRecords < ActiveRecord::Migration[8.0]
  def up
    # Backfill WalletLedgerEntry tokens
    WalletLedgerEntry.where(token: nil).find_each do |entry|
      entry.update_column(:token, SecureRandom.urlsafe_base64(12))
    end

    # Backfill PaymentMethod tokens
    PaymentMethod.where(token: nil).find_each do |pm|
      pm.update_column(:token, SecureRandom.urlsafe_base64(12))
    end

    # Make columns non-nullable now that all records have tokens
    change_column_null :wallet_ledger_entries, :token, false
    change_column_null :payment_methods, :token, false
  end

  def down
    change_column_null :wallet_ledger_entries, :token, true
    change_column_null :payment_methods, :token, true
  end
end

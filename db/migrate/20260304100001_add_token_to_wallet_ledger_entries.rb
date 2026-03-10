class AddTokenToWalletLedgerEntries < ActiveRecord::Migration[8.0]
  def change
    add_column :wallet_ledger_entries, :token, :string
    add_index :wallet_ledger_entries, :token, unique: true
  end
end

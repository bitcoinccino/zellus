class AddSourceContextToWalletLedgerEntries < ActiveRecord::Migration[8.0]
  def change
    add_column :wallet_ledger_entries, :source_context, :string
  end
end

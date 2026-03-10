class AddAssetToWalletLedgerEntries < ActiveRecord::Migration[8.0]
  def change
    add_column :wallet_ledger_entries, :asset, :string, default: "htg", null: false
    add_index  :wallet_ledger_entries, [:wallet_id, :asset, :created_at],
               name: "idx_wallet_ledger_wallet_asset_created"
  end
end

class WidenWalletLedgerPrecision < ActiveRecord::Migration[8.0]
  def change
    change_column :wallet_ledger_entries, :amount,        :decimal, precision: 15, scale: 6, null: false
    change_column :wallet_ledger_entries, :balance_after,  :decimal, precision: 15, scale: 6, null: false
  end
end

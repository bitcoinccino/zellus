class CreateWalletLedgerEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :wallet_ledger_entries do |t|
      t.references :wallet, null: false, foreign_key: true
      t.references :user,   null: true,  foreign_key: true
      t.string     :entry_type, null: false
      t.decimal    :amount,        precision: 15, scale: 2, null: false
      t.decimal    :balance_after, precision: 15, scale: 2, null: false
      t.string     :reference_type
      t.bigint     :reference_id
      t.string     :moncash_transaction_id
      t.string     :description
      t.timestamps
    end

    add_index :wallet_ledger_entries, [ :wallet_id, :created_at ]
    add_index :wallet_ledger_entries, :entry_type
    add_index :wallet_ledger_entries, [ :reference_type, :reference_id ]
    add_index :wallet_ledger_entries, :moncash_transaction_id, unique: true,
              where: "moncash_transaction_id IS NOT NULL",
              name: "idx_wallet_ledger_moncash_tx_uniq"
  end
end

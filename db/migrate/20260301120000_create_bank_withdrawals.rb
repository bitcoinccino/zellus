class CreateBankWithdrawals < ActiveRecord::Migration[8.0]
  def change
    create_table :bank_withdrawals do |t|
      t.references :user, null: false, foreign_key: true
      t.references :wallet, null: false, foreign_key: true
      t.references :wallet_ledger_entry, foreign_key: true
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.string :bank_name, null: false, default: "UNIBANK"
      t.string :bank_account_number, null: false
      t.string :account_holder_name
      t.string :status, null: false, default: "pending"
      t.string :admin_note
      t.string :reference_number
      t.datetime :processed_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :bank_withdrawals, :status
  end
end

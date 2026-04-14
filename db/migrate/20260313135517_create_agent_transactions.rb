class CreateAgentTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_transactions do |t|
      t.references :business, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: { to_table: :users }
      t.references :wallet_ledger_entry, foreign_key: true

      t.decimal  :amount, precision: 15, scale: 2, null: false
      t.string   :currency, default: "HTG", null: false
      t.string   :transaction_type, null: false  # cash_in, cash_out
      t.decimal  :commission_rate, precision: 5, scale: 4, null: false
      t.decimal  :commission_amount, precision: 15, scale: 2, null: false
      t.string   :status, default: "pending", null: false  # pending, completed, failed, disputed
      t.string   :confirmation_code, null: false
      t.string   :idempotency_key
      t.text     :notes

      t.timestamps
    end

    add_index :agent_transactions, :confirmation_code, unique: true
    add_index :agent_transactions, :idempotency_key, unique: true, where: "idempotency_key IS NOT NULL"
    add_index :agent_transactions, :status
    add_index :agent_transactions, :transaction_type
    add_index :agent_transactions, [:business_id, :created_at]
    add_index :agent_transactions, [:customer_id, :created_at]
  end
end

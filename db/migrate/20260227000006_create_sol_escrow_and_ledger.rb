class CreateSolEscrowAndLedger < ActiveRecord::Migration[8.0]
  def change
    # One escrow account per Sol circle — tracks the pool balance
    create_table :sol_escrow_accounts do |t|
      t.references :sol_circle, null: false, foreign_key: true, index: { unique: true }
      t.decimal    :htg_balance,  precision: 15, scale: 2, default: 0, null: false
      t.decimal    :usdc_balance, precision: 15, scale: 6, default: 0, null: false
      t.integer    :status, default: 0, null: false # open / frozen / closed
      t.timestamps
    end

    # Immutable audit ledger — every fund movement is recorded
    create_table :sol_ledger_entries do |t|
      t.references :sol_escrow_account, null: false, foreign_key: true
      t.references :sol_round,          null: true,  foreign_key: true
      t.references :user,               null: true,  foreign_key: true
      t.string     :entry_type,   null: false # deposit, payout, platform_fee, creator_fee, refund
      t.string     :asset,        null: false # htg, usdc
      t.decimal    :amount,       precision: 15, scale: 6, null: false
      t.decimal    :balance_after, precision: 15, scale: 6, null: false
      t.string     :reference_type  # Transaction, PaymentRequest
      t.bigint     :reference_id
      t.string     :description
      t.timestamps
    end

    add_index :sol_ledger_entries, [ :sol_escrow_account_id, :created_at ]
    add_index :sol_ledger_entries, [ :entry_type ]
    add_index :sol_ledger_entries, [ :reference_type, :reference_id ]
  end
end

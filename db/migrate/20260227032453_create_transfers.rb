class CreateTransfers < ActiveRecord::Migration[8.0]
  def change
    create_table :transfers do |t|
      t.references :user, null: false, foreign_key: true

      t.string  :token,                  null: false
      t.string  :status,                 null: false, default: "pending"
      t.decimal :amount,                 precision: 15, scale: 2, null: false
      t.decimal :fee,                    precision: 15, scale: 2, default: 0
      t.decimal :net_amount,             precision: 15, scale: 2

      t.string  :receiver_phone
      t.string  :receiver_email
      t.string  :receiver_name
      t.text    :note

      t.string  :moncash_order_id
      t.string  :moncash_transaction_id
      t.string  :failure_reason

      t.datetime :funded_at
      t.datetime :completed_at
      t.datetime :expires_at

      t.timestamps
    end

    add_index :transfers, :token, unique: true
    add_index :transfers, :status
  end
end

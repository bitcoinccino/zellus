class CreatePaymentRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :payment_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token, null: false
      t.string :status, null: false, default: "active"
      t.string :asset, null: false, default: "htg"
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.string :payer_name
      t.text :note
      t.datetime :expires_at

      t.timestamps
    end

    add_index :payment_requests, :token, unique: true
    add_index :payment_requests, [:user_id, :status]
  end
end

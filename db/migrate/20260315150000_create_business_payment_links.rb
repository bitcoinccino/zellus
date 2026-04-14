class CreateBusinessPaymentLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :business_payment_links do |t|
      t.references :business, null: false, foreign_key: true
      t.string :token, null: false
      t.decimal :amount, precision: 15, scale: 2
      t.string :asset, default: "htg", null: false
      t.string :note, limit: 280
      t.string :status, default: "active", null: false
      t.boolean :single_use, default: false, null: false
      t.integer :times_paid, default: 0, null: false
      t.datetime :expires_at

      t.timestamps
    end

    add_index :business_payment_links, :token, unique: true
    add_index :business_payment_links, [:business_id, :status]
  end
end

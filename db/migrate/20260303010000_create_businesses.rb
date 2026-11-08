class CreateBusinesses < ActiveRecord::Migration[8.0]
  def change
    create_table :businesses do |t|
      t.references :user, null: false, foreign_key: true

      # Identity
      t.string :name,     null: false
      t.string :slug,     null: false
      t.string :category, null: false, default: "lot"
      t.string :description

      # Location
      t.string :commune
      t.string :department
      t.string :address
      t.string :phone

      # Payment config
      t.string  :accepted_currencies, array: true, default: [ "htg" ]
      t.boolean :auto_settle,         default: false
      t.string  :settlement_method,   default: "wallet"
      t.decimal :fee_rate, precision: 5, scale: 4, default: 0.015

      # Verification
      t.string   :status, null: false, default: "pending"
      t.datetime :verified_at
      t.string   :tax_id
      t.boolean  :bonid_verified, default: false

      # Tracking
      t.decimal :total_received,    precision: 15, scale: 2, default: 0
      t.integer :transaction_count, default: 0
      t.decimal :monthly_volume,    precision: 15, scale: 2, default: 0

      t.timestamps
    end

    add_index :businesses, :slug, unique: true
    add_index :businesses, :status
  end
end

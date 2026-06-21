class CreateTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :transactions do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :status, default: 0 # Start as 'pending'

      # HTG usually has 2 decimal places
      t.decimal :fiat_amount, precision: 15, scale: 2

      # USDC on Polygon has 6 decimal places
      t.decimal :crypto_amount, precision: 18, scale: 6

      # Exchange rates need high precision
      t.decimal :exchange_rate, precision: 12, scale: 4

      t.string :destination_address
      t.string :moncash_transaction_id
      t.string :blockchain_tx_hash

      t.timestamps
    end
  end
end

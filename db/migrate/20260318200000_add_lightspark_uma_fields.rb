class AddLightsparkUmaFields < ActiveRecord::Migration[8.0]
  def change
    # Idempotency key for incoming UMA payments (same pattern as circle_transfer_id)
    add_column :wallet_ledger_entries, :lightspark_payment_id, :string
    add_index  :wallet_ledger_entries, :lightspark_payment_id,
               unique: true, where: "lightspark_payment_id IS NOT NULL",
               name: "idx_wallet_ledger_lightspark_payment_uniq"

    # Per-user UMA toggle + Grid customer reference
    add_column :users, :uma_enabled, :boolean, default: true, null: false
    add_column :users, :lightspark_customer_id, :string
    add_index  :users, :lightspark_customer_id,
               unique: true, where: "lightspark_customer_id IS NOT NULL",
               name: "index_users_on_lightspark_customer_id"
  end
end

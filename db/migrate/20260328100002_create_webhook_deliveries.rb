class CreateWebhookDeliveries < ActiveRecord::Migration[8.0]
  def change
    create_table :webhook_deliveries do |t|
      t.references :oauth_client, null: false, foreign_key: true
      t.string :event, null: false
      t.string :delivery_id, null: false
      t.json :payload, null: false
      t.integer :response_status
      t.text :response_body
      t.integer :attempts, default: 0
      t.string :status, default: "pending"
      t.datetime :delivered_at
      t.datetime :next_retry_at
      t.timestamps
    end
    add_index :webhook_deliveries, :delivery_id, unique: true
    add_index :webhook_deliveries, [ :oauth_client_id, :event ]
  end
end

class CreateApiIdempotencyKeys < ActiveRecord::Migration[8.0]
  def change
    create_table :api_idempotency_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :idempotency_key, null: false
      t.string :request_path, null: false
      t.integer :response_status
      t.text :response_body
      t.datetime :locked_at
      t.timestamps
    end
    add_index :api_idempotency_keys, [ :user_id, :idempotency_key ], unique: true
  end
end

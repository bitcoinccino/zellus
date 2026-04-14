class CreateCheckoutSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :checkout_sessions do |t|
      t.references :oauth_client, null: true, foreign_key: true
      t.string     :token,            null: false
      t.string     :status,           null: false, default: "pending"
      t.decimal    :amount,           null: false, precision: 15, scale: 2
      t.string     :currency,         null: false, default: "htg"
      t.text       :description
      t.jsonb      :metadata,         null: false, default: {}
      t.string     :success_url,      null: false
      t.string     :cancel_url
      t.string     :receiver_cashtag, null: false
      t.references :payer, null: true, foreign_key: { to_table: :users }
      t.references :transfer, null: true, foreign_key: true
      t.string     :failure_reason
      t.datetime   :expires_at,       null: false
      t.datetime   :completed_at

      t.timestamps
    end

    add_index :checkout_sessions, :token, unique: true
    add_index :checkout_sessions, :status
  end
end

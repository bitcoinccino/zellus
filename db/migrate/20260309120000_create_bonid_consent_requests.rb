class CreateBonidConsentRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :bonid_consent_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.references :transfer, null: false, foreign_key: true
      t.string  :consent_token, null: false
      t.string  :bonid, null: false
      t.string  :reference_id, null: false
      t.string  :status, default: "pending", null: false
      t.decimal :amount, precision: 15, scale: 2
      t.string  :transaction_type
      t.string  :signature
      t.datetime :decided_at
      t.datetime :expires_at
      t.timestamps

      t.index :consent_token, unique: true
      t.index :reference_id, unique: true
    end
  end
end

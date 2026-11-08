class CreateEmailOtps < ActiveRecord::Migration[8.0]
  def change
    create_table :email_otps do |t|
      t.string   :email,           null: false
      t.string   :code_digest,     null: false
      t.datetime :expires_at,      null: false
      t.integer  :attempts,        null: false, default: 0
      t.datetime :consumed_at
      t.string   :last_request_ip
      t.string   :purpose,         null: false, default: "login"

      t.timestamps
    end

    add_index :email_otps, :email
    add_index :email_otps, [ :email, :consumed_at, :expires_at ], name: "idx_email_otps_lookup"
  end
end

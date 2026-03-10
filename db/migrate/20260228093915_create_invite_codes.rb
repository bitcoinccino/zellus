class CreateInviteCodes < ActiveRecord::Migration[8.0]
  def change
    create_table :invite_codes do |t|
      t.string :code, null: false
      t.string :region, null: false, default: "cotes_de_fer"
      t.string :label
      t.integer :max_uses, null: false, default: 1
      t.integer :uses_count, null: false, default: 0
      t.datetime :expires_at
      t.boolean :active, null: false, default: true
      t.references :creator, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end
    add_index :invite_codes, :code, unique: true
    add_index :invite_codes, :region

    # Track which invite code each user used
    add_reference :users, :invite_code, foreign_key: true
  end
end

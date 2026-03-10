class AddCashtagAndPhoneToUsersAndTransfers < ActiveRecord::Migration[8.0]
  def change
    # ── Users: identity fields ──
    add_column :users, :cashtag, :string
    add_column :users, :phone_number, :string
    add_column :users, :cashtag_changed_at, :datetime
    add_column :users, :invited_by_id, :bigint

    add_index :users, :cashtag, unique: true
    add_index :users, :phone_number, unique: true, where: "phone_number IS NOT NULL"
    add_foreign_key :users, :users, column: :invited_by_id

    # ── Transfers: receiver cashtag ──
    add_column :transfers, :receiver_cashtag, :string
  end
end

class AddTokenToNotifications < ActiveRecord::Migration[8.0]
  def up
    add_column :notifications, :token, :string

    # Backfill existing records with short tokens
    Notification.reset_column_information
    Notification.where(token: nil).find_each do |n|
      n.update_column(:token, SecureRandom.urlsafe_base64(12))
    end

    change_column_null :notifications, :token, false
    add_index :notifications, :token, unique: true
  end

  def down
    remove_index :notifications, :token
    remove_column :notifications, :token
  end
end

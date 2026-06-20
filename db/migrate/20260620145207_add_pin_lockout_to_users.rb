class AddPinLockoutToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :failed_pin_attempts, :integer, null: false, default: 0
    add_column :users, :pin_locked_until, :datetime
  end
end

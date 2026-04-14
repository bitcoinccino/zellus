class AddDailyTransferLimitOverrideToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :daily_transfer_limit_override, :decimal
  end
end

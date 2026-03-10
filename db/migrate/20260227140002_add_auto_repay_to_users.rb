class AddAutoRepayToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :auto_repay_enabled, :boolean, default: false, null: false
  end
end

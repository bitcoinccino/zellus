class AddTransferPinToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :transfer_pin_digest, :string
    add_column :users, :transfer_pin_set_at, :datetime
  end
end

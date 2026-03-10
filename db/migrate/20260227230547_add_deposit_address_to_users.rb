class AddDepositAddressToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :deposit_address, :string
    add_index :users, :deposit_address, unique: true, where: "deposit_address IS NOT NULL"
  end
end

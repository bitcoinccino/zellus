class AddCircleFields < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :circle_wallet_id, :string
    add_column :users, :circle_wallet_address, :string
    add_index :users, :circle_wallet_id, unique: true, where: "circle_wallet_id IS NOT NULL"
    add_index :users, :circle_wallet_address, unique: true, where: "circle_wallet_address IS NOT NULL"

    add_column :wallet_ledger_entries, :circle_transfer_id, :string
    add_index :wallet_ledger_entries, :circle_transfer_id, unique: true, where: "circle_transfer_id IS NOT NULL"
  end
end

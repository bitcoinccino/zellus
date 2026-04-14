class AddAdminSearchIndexes < ActiveRecord::Migration[8.0]
  def change
    add_index :transactions, :blockchain_tx_hash, if_not_exists: true
    add_index :users, "LOWER(cashtag)", name: "index_users_on_lower_cashtag", if_not_exists: true
  end
end

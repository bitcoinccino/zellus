class AddBonidFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :bonid, :string
    add_column :users, :bonid_verified_at, :datetime
    add_column :users, :bonid_first_name, :string
    add_column :users, :bonid_last_name, :string
    add_column :users, :bonid_photo_url, :string
    add_index  :users, :bonid, unique: true, where: "bonid IS NOT NULL"
  end
end

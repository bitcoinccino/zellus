class AddBonidAddressToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :bonid_street, :string
    add_column :users, :bonid_locality, :string
    add_column :users, :bonid_commune, :string
    add_column :users, :bonid_department, :string
    add_column :users, :bonid_country, :string
  end
end

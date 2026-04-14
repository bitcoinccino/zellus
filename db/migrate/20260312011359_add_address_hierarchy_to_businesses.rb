class AddAddressHierarchyToBusinesses < ActiveRecord::Migration[8.0]
  def change
    add_column :businesses, :arrondissement, :string
    add_column :businesses, :section, :string
  end
end

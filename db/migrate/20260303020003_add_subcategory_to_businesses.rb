class AddSubcategoryToBusinesses < ActiveRecord::Migration[8.0]
  def change
    add_column :businesses, :subcategory, :string
  end
end

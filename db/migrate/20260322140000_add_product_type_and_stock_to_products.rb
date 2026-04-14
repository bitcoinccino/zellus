class AddProductTypeAndStockToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :product_type, :string, default: "good", null: false
    add_column :products, :stock, :integer, default: nil
  end
end

class AddAssetToProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :products, :asset, :string, default: "htg", null: false
  end
end

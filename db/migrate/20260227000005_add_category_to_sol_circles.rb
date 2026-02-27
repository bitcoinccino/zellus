class AddCategoryToSolCircles < ActiveRecord::Migration[8.0]
  def change
    add_column :sol_circles, :category, :integer, default: 0, null: false
  end
end

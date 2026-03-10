class AddRotationTypeToSolCircles < ActiveRecord::Migration[8.0]
  def change
    add_column :sol_circles, :rotation_type, :integer, default: 0, null: false
  end
end

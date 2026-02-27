class AddCreationFieldsToSolCircles < ActiveRecord::Migration[8.0]
  def change
    add_reference :sol_circles, :user, foreign_key: true
    add_column :sol_circles, :asset, :string, default: "htg", null: false
    add_column :sol_circles, :target_members, :integer, default: 5, null: false
  end
end

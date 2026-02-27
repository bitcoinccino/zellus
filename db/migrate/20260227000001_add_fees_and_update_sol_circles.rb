class AddFeesAndUpdateSolCircles < ActiveRecord::Migration[8.0]
  def change
    add_column :sol_circles, :platform_fee_percent, :decimal, precision: 5, scale: 2, default: 2.0, null: false
    add_column :sol_circles, :creator_fee_percent, :decimal, precision: 5, scale: 2, default: 0.0, null: false

    # Add defaulted_at to sol_memberships for tracking members who can't pay
    add_column :sol_memberships, :defaulted_at, :datetime
    add_column :sol_memberships, :active, :boolean, default: true, null: false
  end
end

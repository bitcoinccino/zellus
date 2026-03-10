class AddPayoutDayToSolCircles < ActiveRecord::Migration[8.0]
  def change
    add_column :sol_circles, :payout_day, :integer, default: 1, null: false
  end
end

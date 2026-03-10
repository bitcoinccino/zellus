class RenamePayoutDayToContributionDayInSolCircles < ActiveRecord::Migration[8.0]
  def change
    rename_column :sol_circles, :payout_day, :contribution_day
  end
end

class UpdateFrequencyEnumInSolCircles < ActiveRecord::Migration[8.0]
  def up
    # Old enum: three_months=0, six_months=1, twelve_months=2
    # New enum: weekly=0, biweekly=1, triweekly=2, monthly=3
    # Convert all existing records to monthly (3) as closest match
    execute "UPDATE sol_circles SET frequency = 3 WHERE frequency IN (0, 1, 2)"
  end

  def down
    # Revert monthly (3) back to six_months (1) as default
    execute "UPDATE sol_circles SET frequency = 1 WHERE frequency = 3"
  end
end

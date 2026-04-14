class AddTipsSupport < ActiveRecord::Migration[8.0]
  def change
    # Business can enable/disable tips on their pay page
    add_column :businesses, :tippable, :boolean, default: false, null: false

    # Track tip amount on each transfer
    add_column :transfers, :tip_amount, :decimal, precision: 15, scale: 2, default: 0
  end
end

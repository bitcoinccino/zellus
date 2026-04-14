class AddUsdcBalanceToBusiness < ActiveRecord::Migration[8.0]
  def change
    add_column :businesses, :usdc_balance, :decimal, precision: 30, scale: 18, default: 0, null: false
  end
end

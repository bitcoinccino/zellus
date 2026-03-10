class AddUsdcBalanceToWallets < ActiveRecord::Migration[8.0]
  def change
    add_column :wallets, :usdc_balance, :decimal, precision: 15, scale: 6, default: 0, null: false
  end
end

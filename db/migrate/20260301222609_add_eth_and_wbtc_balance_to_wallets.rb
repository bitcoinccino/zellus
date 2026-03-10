class AddEthAndWbtcBalanceToWallets < ActiveRecord::Migration[8.0]
  def change
    add_column :wallets, :eth_balance, :decimal, precision: 18, scale: 8, default: 0.0, null: false
    add_column :wallets, :wbtc_balance, :decimal, precision: 18, scale: 8, default: 0.0, null: false
  end
end

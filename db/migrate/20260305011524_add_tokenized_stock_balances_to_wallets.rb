class AddTokenizedStockBalancesToWallets < ActiveRecord::Migration[8.0]
  def change
    add_column :wallets, :tslax_balance,  :decimal, precision: 18, scale: 8, default: 0.0, null: false
    add_column :wallets, :nvdax_balance,  :decimal, precision: 18, scale: 8, default: 0.0, null: false
    add_column :wallets, :aaplx_balance,  :decimal, precision: 18, scale: 8, default: 0.0, null: false
    add_column :wallets, :coinx_balance,  :decimal, precision: 18, scale: 8, default: 0.0, null: false
    add_column :wallets, :googlx_balance, :decimal, precision: 18, scale: 8, default: 0.0, null: false
  end
end

class AddAssetFieldsToTransfers < ActiveRecord::Migration[8.0]
  def change
    add_column :transfers, :asset, :string, null: false, default: "htg"
    add_column :transfers, :receiver_wallet_address, :string
    add_column :transfers, :crypto_amount, :decimal, precision: 18, scale: 8
    add_column :transfers, :exchange_rate, :decimal, precision: 15, scale: 2
    add_column :transfers, :blockchain_tx_hash, :string

    change_column_null :transfers, :receiver_name, true
    change_column_default :transfers, :receiver_name, nil
  end
end

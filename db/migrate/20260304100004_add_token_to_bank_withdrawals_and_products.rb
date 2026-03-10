class AddTokenToBankWithdrawalsAndProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_withdrawals, :token, :string
    add_index :bank_withdrawals, :token, unique: true

    add_column :products, :token, :string
    add_index :products, :token, unique: true
  end
end

class AddCurrencyToBankWithdrawals < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_withdrawals, :currency, :string, default: "htg", null: false
  end
end

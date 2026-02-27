class AddFeeToTransactions < ActiveRecord::Migration[8.0]
  def change
    # Precision 15, scale 2 is perfect for HTG fees
    add_column :transactions, :fee_amount, :decimal, precision: 15, scale: 2, default: 0.0
  end
end

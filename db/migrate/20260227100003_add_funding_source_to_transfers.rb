class AddFundingSourceToTransfers < ActiveRecord::Migration[8.0]
  def change
    add_column :transfers, :funding_source, :string, default: "moncash", null: false
    add_column :transfers, :payout_method,  :string
  end
end

class AddLastMoncashOrderIdToTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :transactions, :last_moncash_order_id, :string
  end
end

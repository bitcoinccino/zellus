class AddBusinessIdToTransfers < ActiveRecord::Migration[8.0]
  def change
    add_reference :transfers, :business, null: true, foreign_key: true
  end
end

class AddFailureReasonToTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :transactions, :failure_reason, :text
  end
end

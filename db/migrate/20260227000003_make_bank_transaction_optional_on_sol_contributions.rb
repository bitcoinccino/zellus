class MakeBankTransactionOptionalOnSolContributions < ActiveRecord::Migration[8.0]
  def change
    change_column_null :sol_contributions, :bank_transaction_id, true
  end
end

class AddLoanFieldsToTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :transactions, :loan_purpose, :string
    add_column :transactions, :repayment_term_weeks, :integer
    add_column :transactions, :collateral_description, :text
    add_column :transactions, :loan_due_date, :date
    add_column :transactions, :loan_interest_rate, :decimal, precision: 5, scale: 4, default: 0.0
    add_column :transactions, :loan_total_repayable, :decimal, precision: 12, scale: 2
  end
end

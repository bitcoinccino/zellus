class AddCreditScoreToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :credit_score, :integer, default: 300, null: false
  end
end

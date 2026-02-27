class ChangeCreditScoreDefaultToZero < ActiveRecord::Migration[8.0]
  def change
    change_column_default :users, :credit_score, from: 300, to: 0
  end
end

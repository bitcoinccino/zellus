class CreateSolRounds < ActiveRecord::Migration[8.0]
  def change
    create_table :sol_rounds do |t|
      t.references :sol_circle, null: false, foreign_key: true
      
      # CHANGE THIS LINE TO LOOK EXACTLY LIKE THIS:
      t.references :payout_user, null: false, foreign_key: { to_table: :users }
      
      t.integer :round_number
      t.integer :status
      t.timestamps
    end
  end
end

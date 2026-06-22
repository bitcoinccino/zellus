class CreateSolContributions < ActiveRecord::Migration[8.0]
  def change
    create_table :sol_contributions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :sol_round, null: false, foreign_key: true

      # FIX THIS LINE TO LOOK EXACTLY LIKE THIS:
      t.references :bank_transaction, null: false, foreign_key: { to_table: :transactions }

      t.integer :status
      t.timestamps
    end
  end
end

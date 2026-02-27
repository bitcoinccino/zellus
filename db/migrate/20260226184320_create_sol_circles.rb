class CreateSolCircles < ActiveRecord::Migration[8.0]
  def change
    create_table :sol_circles do |t|
      t.string :name
      t.decimal :amount
      t.integer :frequency
      t.integer :status
      t.datetime :start_date
      t.string :token

      t.timestamps
    end
    add_index :sol_circles, :token
  end
end

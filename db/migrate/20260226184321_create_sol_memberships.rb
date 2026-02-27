class CreateSolMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :sol_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :sol_circle, null: false, foreign_key: true
      t.integer :position

      t.timestamps
    end
  end
end

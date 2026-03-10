class AddTokenToSolMemberships < ActiveRecord::Migration[8.0]
  def change
    add_column :sol_memberships, :token, :string
    add_index  :sol_memberships, :token, unique: true
  end
end

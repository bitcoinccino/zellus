class AddBonidBloodTypeToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :bonid_blood_type, :string
  end
end

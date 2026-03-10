class AddBonidRecheckedAtToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :bonid_rechecked_at, :datetime
  end
end

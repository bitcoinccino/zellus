class AddOutgoingFundsHeldUntilToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :outgoing_funds_held_until, :datetime
  end
end

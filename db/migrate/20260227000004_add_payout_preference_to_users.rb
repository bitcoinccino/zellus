class AddPayoutPreferenceToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :payout_preference, :string, default: "auto", null: false
  end
end

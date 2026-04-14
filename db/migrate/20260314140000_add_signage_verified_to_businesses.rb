class AddSignageVerifiedToBusinesses < ActiveRecord::Migration[8.0]
  def change
    add_column :businesses, :signage_verified, :boolean, default: false, null: false
  end
end

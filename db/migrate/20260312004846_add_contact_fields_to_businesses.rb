class AddContactFieldsToBusinesses < ActiveRecord::Migration[8.0]
  def change
    add_column :businesses, :email, :string
    add_column :businesses, :website, :string
    add_column :businesses, :social_media, :jsonb, default: {}
    add_column :businesses, :hours, :string
  end
end

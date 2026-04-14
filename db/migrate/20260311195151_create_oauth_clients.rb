class CreateOauthClients < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_clients do |t|
      t.string :name
      t.string :client_id
      t.string :client_secret
      t.string :redirect_uri
      t.text :scopes
      t.boolean :active, default: true, null: false

      t.timestamps
    end
    add_index :oauth_clients, :client_id, unique: true
  end
end

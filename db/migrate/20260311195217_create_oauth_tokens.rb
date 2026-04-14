class CreateOauthTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.references :oauth_client, null: false, foreign_key: true
      t.string :access_token
      t.string :refresh_token
      t.string :authorization_code
      t.text :scopes
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :code_expires_at

      t.timestamps
    end
    add_index :oauth_tokens, :access_token, unique: true
    add_index :oauth_tokens, :authorization_code, unique: true
    add_index :oauth_tokens, :refresh_token, unique: true
  end
end

class AddWebhookFieldsToOauthClients < ActiveRecord::Migration[8.0]
  def change
    add_column :oauth_clients, :webhook_url, :string
    add_column :oauth_clients, :webhook_secret, :string
    add_column :oauth_clients, :webhook_events, :string, array: true, default: []
    add_column :oauth_clients, :webhook_active, :boolean, default: false
  end
end

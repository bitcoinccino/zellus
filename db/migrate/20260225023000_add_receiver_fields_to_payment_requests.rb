class AddReceiverFieldsToPaymentRequests < ActiveRecord::Migration[8.0]
  def change
    add_reference :payment_requests, :payment_method, null: true, foreign_key: true

    add_column :payment_requests, :receiver_category, :string
    add_column :payment_requests, :receiver_provider, :string
    add_column :payment_requests, :receiver_network, :string
    add_column :payment_requests, :receiver_asset, :string
    add_column :payment_requests, :receiver_label, :string
    add_column :payment_requests, :receiver_account_number, :string
    add_column :payment_requests, :receiver_wallet_address, :string
  end
end

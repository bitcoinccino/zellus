class ExtendPaymentMethodsForCategories < ActiveRecord::Migration[8.0]
  def change
    add_column :payment_methods, :category, :string, null: false, default: "mobile_wallet"
    add_column :payment_methods, :network, :string
    add_column :payment_methods, :asset, :string
    add_column :payment_methods, :wallet_address, :string

    add_index :payment_methods, [ :user_id, :category, :provider ]
    add_index :payment_methods, [ :user_id, :category, :wallet_address ], unique: true
  end
end

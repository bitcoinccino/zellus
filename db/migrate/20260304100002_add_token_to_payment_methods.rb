class AddTokenToPaymentMethods < ActiveRecord::Migration[8.0]
  def change
    add_column :payment_methods, :token, :string
    add_index :payment_methods, :token, unique: true
  end
end

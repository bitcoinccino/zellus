class AddIsDefaultToPaymentMethods < ActiveRecord::Migration[8.0]
  def change
    add_column :payment_methods, :is_default, :boolean, default: false, null: false
  end
end

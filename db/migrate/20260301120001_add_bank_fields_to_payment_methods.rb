class AddBankFieldsToPaymentMethods < ActiveRecord::Migration[8.0]
  def change
    add_column :payment_methods, :bank_account_number, :string
    add_column :payment_methods, :bank_name, :string
    add_column :payment_methods, :account_holder_name, :string
  end
end

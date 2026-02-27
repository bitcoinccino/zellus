class AllowNullAccountNumberOnPaymentMethods < ActiveRecord::Migration[8.0]
  def change
    change_column_null :payment_methods, :account_number, true
  end
end

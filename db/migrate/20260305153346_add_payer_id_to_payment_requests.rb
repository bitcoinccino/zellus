class AddPayerIdToPaymentRequests < ActiveRecord::Migration[8.0]
  def change
    add_reference :payment_requests, :payer, null: true, foreign_key: { to_table: :users }, index: true
  end
end

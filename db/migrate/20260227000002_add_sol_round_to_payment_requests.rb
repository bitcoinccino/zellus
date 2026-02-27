class AddSolRoundToPaymentRequests < ActiveRecord::Migration[8.0]
  def change
    add_reference :payment_requests, :sol_round, null: true, foreign_key: true
  end
end

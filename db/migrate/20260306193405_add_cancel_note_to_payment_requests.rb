class AddCancelNoteToPaymentRequests < ActiveRecord::Migration[8.0]
  def change
    add_column :payment_requests, :cancel_note, :text
  end
end

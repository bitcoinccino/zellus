class AddRefundFieldsToCheckoutSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :checkout_sessions, :refunded_at, :datetime
  end
end

class AddItemsToPaymentLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :business_payment_links, :items, :jsonb, default: []
  end
end

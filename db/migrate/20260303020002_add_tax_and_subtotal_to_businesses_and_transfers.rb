class AddTaxAndSubtotalToBusinessesAndTransfers < ActiveRecord::Migration[8.0]
  def change
    # Fixed tax rate per business (e.g. 0.10 = 10%)
    add_column :businesses, :tax_rate, :decimal, precision: 5, scale: 4, default: 0

    # Only populated for business transfers with line items
    add_column :transfers, :subtotal,   :decimal, precision: 12, scale: 2
    add_column :transfers, :tax_amount, :decimal, precision: 12, scale: 2
  end
end

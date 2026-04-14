class AddAllowTipsToPaymentLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :business_payment_links, :allow_tips, :boolean, default: false, null: false
  end
end

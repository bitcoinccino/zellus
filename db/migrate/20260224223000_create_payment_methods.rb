class CreatePaymentMethods < ActiveRecord::Migration[8.0]
  def change
    create_table :payment_methods do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false, default: "moncash"
      t.string :account_number, null: false
      t.string :label
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :payment_methods, [ :user_id, :provider, :account_number ], unique: true
    add_index :payment_methods, [ :user_id, :active ]
  end
end

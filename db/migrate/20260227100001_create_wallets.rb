class CreateWallets < ActiveRecord::Migration[8.0]
  def change
    create_table :wallets do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.decimal    :htg_balance, precision: 15, scale: 2, default: 0, null: false
      t.integer    :status, default: 0, null: false # open:0, held:1, closed:2
      t.timestamps
    end
  end
end

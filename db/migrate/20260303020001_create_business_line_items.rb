class CreateBusinessLineItems < ActiveRecord::Migration[8.0]
  def change
    create_table :business_line_items do |t|
      t.references :transfer, null: false, foreign_key: true
      t.references :product,  null: true,  foreign_key: true

      t.string  :name,       null: false
      t.integer :quantity,   null: false, default: 1
      t.decimal :unit_price, precision: 12, scale: 2, null: false
      t.decimal :line_total, precision: 12, scale: 2, null: false

      t.timestamps
    end
  end
end

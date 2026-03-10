class CreateProducts < ActiveRecord::Migration[8.0]
  def change
    create_table :products do |t|
      t.references :business, null: false, foreign_key: true

      t.string  :name,          null: false
      t.decimal :price,         precision: 12, scale: 2, null: false
      t.string  :description
      t.integer :position,      default: 0
      t.boolean :active,        default: true

      # Denormalized analytics
      t.integer :sold_count,    default: 0
      t.decimal :total_revenue, precision: 15, scale: 2, default: 0

      t.timestamps
    end

    add_index :products, [:business_id, :active]
    add_index :products, [:business_id, :sold_count]
  end
end

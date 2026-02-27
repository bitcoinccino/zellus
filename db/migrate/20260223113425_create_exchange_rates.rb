class CreateExchangeRates < ActiveRecord::Migration[8.0]
  def change
    create_table :exchange_rates do |t|
      t.string :from_currency
      t.string :to_currency
      t.decimal :rate

      t.timestamps
    end
  end
end

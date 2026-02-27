class AddTransactionTypeAndCryptoToTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :transactions, :transaction_type, :string, default: "buy", null: false
    add_column :transactions, :crypto_currency,  :string, default: "usdc", null: false
    add_column :transactions, :moncash_phone,    :string
  end
end

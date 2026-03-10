# frozen_string_literal: true

class AddTokenToTransactions < ActiveRecord::Migration[8.0]
  def up
    add_column :transactions, :token, :string

    # Backfill existing records using Ruby
    Transaction.reset_column_information
    Transaction.where(token: nil).find_each do |t|
      t.update_column(:token, SecureRandom.urlsafe_base64(12))
    end

    change_column_null :transactions, :token, false
    add_index :transactions, :token, unique: true
  end

  def down
    remove_index :transactions, :token
    remove_column :transactions, :token
  end
end

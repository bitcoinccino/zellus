class AddBankFieldsToTransfers < ActiveRecord::Migration[8.0]
  def change
    add_column :transfers, :receiver_bank_account, :string
    add_column :transfers, :receiver_bank_name, :string, default: "UNIBANK"
    add_column :transfers, :receiver_account_holder, :string
  end
end

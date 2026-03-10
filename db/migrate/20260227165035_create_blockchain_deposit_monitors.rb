class CreateBlockchainDepositMonitors < ActiveRecord::Migration[8.0]
  def change
    create_table :blockchain_deposit_monitors do |t|
      t.string :name, null: false
      t.bigint :last_processed_block, default: 0, null: false

      t.timestamps
    end
    add_index :blockchain_deposit_monitors, :name, unique: true
  end
end

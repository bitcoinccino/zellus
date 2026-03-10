class CreateTreasurySweeps < ActiveRecord::Migration[8.0]
  def change
    create_table :treasury_sweeps do |t|
      t.references :user, null: false, foreign_key: true
      t.string     :asset,                null: false
      t.decimal    :amount,               precision: 18, scale: 8, null: false
      t.string     :from_address,         null: false
      t.string     :to_address,           null: false
      t.string     :gas_funding_tx_hash
      t.string     :sweep_tx_hash
      t.string     :status,               null: false, default: "pending"
      t.string     :failure_reason
      t.integer    :confirmation_attempts, default: 0
      t.timestamps
    end

    add_index :treasury_sweeps, :status
    add_index :treasury_sweeps, [:user_id, :asset, :status]
    add_index :treasury_sweeps, :sweep_tx_hash, unique: true, where: "sweep_tx_hash IS NOT NULL"
  end
end

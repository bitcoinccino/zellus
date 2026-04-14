class AddAgentFieldsToBusinesses < ActiveRecord::Migration[8.0]
  def change
    add_column :businesses, :is_agent, :boolean, default: false, null: false
    add_column :businesses, :agent_activated_at, :datetime
    add_column :businesses, :agent_commission_rate, :decimal, precision: 5, scale: 4, default: 0.02, null: false
    add_column :businesses, :total_commission_earned, :decimal, precision: 15, scale: 2, default: 0, null: false

    add_index :businesses, :is_agent
  end
end

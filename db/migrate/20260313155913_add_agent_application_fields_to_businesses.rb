class AddAgentApplicationFieldsToBusinesses < ActiveRecord::Migration[8.0]
  def change
    add_column :businesses, :agent_status, :string, default: "none", null: false
    add_column :businesses, :agent_rejected_reason, :text
    add_column :businesses, :agent_applied_at, :datetime

    add_index :businesses, :agent_status
  end
end

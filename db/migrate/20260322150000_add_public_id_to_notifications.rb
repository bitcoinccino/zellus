class AddPublicIdToNotifications < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    add_column :notifications, :public_id, :uuid, default: "gen_random_uuid()", null: false
    add_index  :notifications, :public_id, unique: true

    # Backfill existing rows (gen_random_uuid() default handles new rows)
    reversible do |dir|
      dir.up do
        execute "UPDATE notifications SET public_id = gen_random_uuid() WHERE public_id IS NULL"
      end
    end
  end
end

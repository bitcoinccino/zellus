# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_03_10_085509) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "bank_withdrawals", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "wallet_id", null: false
    t.bigint "wallet_ledger_entry_id"
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "bank_name", default: "UNIBANK", null: false
    t.string "bank_account_number", null: false
    t.string "account_holder_name"
    t.string "status", default: "pending", null: false
    t.string "admin_note"
    t.string "reference_number"
    t.datetime "processed_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "currency", default: "htg", null: false
    t.string "token", null: false
    t.index ["status"], name: "index_bank_withdrawals_on_status"
    t.index ["token"], name: "index_bank_withdrawals_on_token", unique: true
    t.index ["user_id"], name: "index_bank_withdrawals_on_user_id"
    t.index ["wallet_id"], name: "index_bank_withdrawals_on_wallet_id"
    t.index ["wallet_ledger_entry_id"], name: "index_bank_withdrawals_on_wallet_ledger_entry_id"
  end

  create_table "blockchain_deposit_monitors", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "last_processed_block", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_blockchain_deposit_monitors_on_name", unique: true
  end

  create_table "bonid_consent_requests", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "transfer_id", null: false
    t.string "consent_token", null: false
    t.string "bonid", null: false
    t.string "reference_id", null: false
    t.string "status", default: "pending", null: false
    t.decimal "amount", precision: 15, scale: 2
    t.string "transaction_type"
    t.string "signature"
    t.datetime "decided_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["consent_token"], name: "index_bonid_consent_requests_on_consent_token", unique: true
    t.index ["reference_id"], name: "index_bonid_consent_requests_on_reference_id", unique: true
    t.index ["transfer_id"], name: "index_bonid_consent_requests_on_transfer_id"
    t.index ["user_id"], name: "index_bonid_consent_requests_on_user_id"
  end

  create_table "business_line_items", force: :cascade do |t|
    t.bigint "transfer_id", null: false
    t.bigint "product_id"
    t.string "name", null: false
    t.integer "quantity", default: 1, null: false
    t.decimal "unit_price", precision: 12, scale: 2, null: false
    t.decimal "line_total", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_business_line_items_on_product_id"
    t.index ["transfer_id"], name: "index_business_line_items_on_transfer_id"
  end

  create_table "businesses", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.string "category", default: "lot", null: false
    t.string "description"
    t.string "commune"
    t.string "department"
    t.string "address"
    t.string "phone"
    t.string "accepted_currencies", default: ["htg"], array: true
    t.boolean "auto_settle", default: false
    t.string "settlement_method", default: "wallet"
    t.decimal "fee_rate", precision: 5, scale: 4, default: "0.015"
    t.string "status", default: "pending", null: false
    t.datetime "verified_at"
    t.string "tax_id"
    t.boolean "bonid_verified", default: false
    t.decimal "total_received", precision: 15, scale: 2, default: "0.0"
    t.integer "transaction_count", default: 0
    t.decimal "monthly_volume", precision: 15, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "tax_rate", precision: 5, scale: 4, default: "0.0"
    t.string "subcategory"
    t.index ["slug"], name: "index_businesses_on_slug", unique: true
    t.index ["status"], name: "index_businesses_on_status"
    t.index ["user_id"], name: "index_businesses_on_user_id"
  end

  create_table "exchange_rates", force: :cascade do |t|
    t.string "from_currency"
    t.string "to_currency"
    t.decimal "rate"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "invite_codes", force: :cascade do |t|
    t.string "code", null: false
    t.string "region", default: "cotes_de_fer", null: false
    t.string "label"
    t.integer "max_uses", default: 1, null: false
    t.integer "uses_count", default: 0, null: false
    t.datetime "expires_at"
    t.boolean "active", default: true, null: false
    t.bigint "creator_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_invite_codes_on_code", unique: true
    t.index ["creator_id"], name: "index_invite_codes_on_creator_id"
    t.index ["region"], name: "index_invite_codes_on_region"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "actor_id"
    t.string "notifiable_type"
    t.bigint "notifiable_id"
    t.string "notification_type", null: false
    t.string "title", null: false
    t.string "body"
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_notifications_on_actor_id"
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["user_id", "created_at"], name: "index_notifications_on_user_id_and_created_at"
    t.index ["user_id", "read_at"], name: "index_notifications_on_user_id_and_read_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "payment_methods", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "provider", default: "moncash", null: false
    t.string "account_number"
    t.string "label"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "category", default: "mobile_wallet", null: false
    t.string "network"
    t.string "asset"
    t.string "wallet_address"
    t.string "bank_account_number"
    t.string "bank_name"
    t.string "account_holder_name"
    t.string "token", null: false
    t.index ["token"], name: "index_payment_methods_on_token", unique: true
    t.index ["user_id", "active"], name: "index_payment_methods_on_user_id_and_active"
    t.index ["user_id", "category", "provider"], name: "index_payment_methods_on_user_id_and_category_and_provider"
    t.index ["user_id", "category", "wallet_address"], name: "idx_on_user_id_category_wallet_address_bdbf12a36f", unique: true
    t.index ["user_id", "provider", "account_number"], name: "idx_on_user_id_provider_account_number_7759ed6046", unique: true
    t.index ["user_id"], name: "index_payment_methods_on_user_id"
  end

  create_table "payment_requests", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token", null: false
    t.string "status", default: "active", null: false
    t.string "asset", default: "htg", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "payer_name"
    t.text "note"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "payment_method_id"
    t.string "receiver_category"
    t.string "receiver_provider"
    t.string "receiver_network"
    t.string "receiver_asset"
    t.string "receiver_label"
    t.string "receiver_account_number"
    t.string "receiver_wallet_address"
    t.bigint "sol_round_id"
    t.bigint "payer_id"
    t.text "cancel_note"
    t.index ["payer_id"], name: "index_payment_requests_on_payer_id"
    t.index ["payment_method_id"], name: "index_payment_requests_on_payment_method_id"
    t.index ["sol_round_id"], name: "index_payment_requests_on_sol_round_id"
    t.index ["token"], name: "index_payment_requests_on_token", unique: true
    t.index ["user_id", "status"], name: "index_payment_requests_on_user_id_and_status"
    t.index ["user_id"], name: "index_payment_requests_on_user_id"
  end

  create_table "products", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.string "name", null: false
    t.decimal "price", precision: 12, scale: 2, null: false
    t.string "description"
    t.integer "position", default: 0
    t.boolean "active", default: true
    t.integer "sold_count", default: 0
    t.decimal "total_revenue", precision: 15, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "token", null: false
    t.index ["business_id", "active"], name: "index_products_on_business_id_and_active"
    t.index ["business_id", "sold_count"], name: "index_products_on_business_id_and_sold_count"
    t.index ["business_id"], name: "index_products_on_business_id"
    t.index ["token"], name: "index_products_on_token", unique: true
  end

  create_table "sol_circles", force: :cascade do |t|
    t.string "name"
    t.decimal "amount"
    t.integer "frequency"
    t.integer "status"
    t.datetime "start_date"
    t.string "token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "asset", default: "htg", null: false
    t.integer "target_members", default: 5, null: false
    t.decimal "platform_fee_percent", precision: 5, scale: 2, default: "2.0", null: false
    t.decimal "creator_fee_percent", precision: 5, scale: 2, default: "0.0", null: false
    t.integer "category", default: 0, null: false
    t.integer "contribution_day", default: 1, null: false
    t.integer "rotation_type", default: 0, null: false
    t.index ["token"], name: "index_sol_circles_on_token"
    t.index ["user_id"], name: "index_sol_circles_on_user_id"
  end

  create_table "sol_contributions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "sol_round_id", null: false
    t.bigint "bank_transaction_id"
    t.integer "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bank_transaction_id"], name: "index_sol_contributions_on_bank_transaction_id"
    t.index ["sol_round_id"], name: "index_sol_contributions_on_sol_round_id"
    t.index ["user_id"], name: "index_sol_contributions_on_user_id"
  end

  create_table "sol_escrow_accounts", force: :cascade do |t|
    t.bigint "sol_circle_id", null: false
    t.decimal "htg_balance", precision: 15, scale: 2, default: "0.0", null: false
    t.decimal "usdc_balance", precision: 15, scale: 6, default: "0.0", null: false
    t.integer "status", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sol_circle_id"], name: "index_sol_escrow_accounts_on_sol_circle_id", unique: true
  end

  create_table "sol_ledger_entries", force: :cascade do |t|
    t.bigint "sol_escrow_account_id", null: false
    t.bigint "sol_round_id"
    t.bigint "user_id"
    t.string "entry_type", null: false
    t.string "asset", null: false
    t.decimal "amount", precision: 15, scale: 6, null: false
    t.decimal "balance_after", precision: 15, scale: 6, null: false
    t.string "reference_type"
    t.bigint "reference_id"
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_type"], name: "index_sol_ledger_entries_on_entry_type"
    t.index ["reference_type", "reference_id"], name: "index_sol_ledger_entries_on_reference_type_and_reference_id"
    t.index ["sol_escrow_account_id", "created_at"], name: "idx_on_sol_escrow_account_id_created_at_333ceaafc0"
    t.index ["sol_escrow_account_id"], name: "index_sol_ledger_entries_on_sol_escrow_account_id"
    t.index ["sol_round_id"], name: "index_sol_ledger_entries_on_sol_round_id"
    t.index ["user_id"], name: "index_sol_ledger_entries_on_user_id"
  end

  create_table "sol_memberships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "sol_circle_id", null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "defaulted_at"
    t.boolean "active", default: true, null: false
    t.string "token", null: false
    t.index ["sol_circle_id"], name: "index_sol_memberships_on_sol_circle_id"
    t.index ["token"], name: "index_sol_memberships_on_token", unique: true
    t.index ["user_id"], name: "index_sol_memberships_on_user_id"
  end

  create_table "sol_rounds", force: :cascade do |t|
    t.bigint "sol_circle_id", null: false
    t.bigint "payout_user_id", null: false
    t.integer "round_number"
    t.integer "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["payout_user_id"], name: "index_sol_rounds_on_payout_user_id"
    t.index ["sol_circle_id"], name: "index_sol_rounds_on_sol_circle_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.binary "payload", null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "transactions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "status", default: 0
    t.decimal "fiat_amount", precision: 15, scale: 2
    t.decimal "crypto_amount", precision: 18, scale: 6
    t.decimal "exchange_rate", precision: 12, scale: 4
    t.string "destination_address"
    t.string "moncash_transaction_id"
    t.string "blockchain_tx_hash"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "fee_amount", precision: 15, scale: 2, default: "0.0"
    t.text "failure_reason"
    t.string "transaction_type", default: "buy", null: false
    t.string "crypto_currency", default: "usdc", null: false
    t.string "moncash_phone"
    t.string "last_moncash_order_id"
    t.string "loan_purpose"
    t.integer "repayment_term_weeks"
    t.text "collateral_description"
    t.date "loan_due_date"
    t.decimal "loan_interest_rate", precision: 5, scale: 4, default: "0.0"
    t.decimal "loan_total_repayable", precision: 12, scale: 2
    t.string "token", null: false
    t.index ["token"], name: "index_transactions_on_token", unique: true
    t.index ["user_id"], name: "index_transactions_on_user_id"
  end

  create_table "transfers", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token", null: false
    t.string "status", default: "pending", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.decimal "fee", precision: 15, scale: 2, default: "0.0"
    t.decimal "net_amount", precision: 15, scale: 2
    t.string "receiver_phone"
    t.string "receiver_email"
    t.string "receiver_name"
    t.text "note"
    t.string "moncash_order_id"
    t.string "moncash_transaction_id"
    t.string "failure_reason"
    t.datetime "funded_at"
    t.datetime "completed_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "asset", default: "htg", null: false
    t.string "receiver_wallet_address"
    t.decimal "crypto_amount", precision: 18, scale: 8
    t.decimal "exchange_rate", precision: 15, scale: 2
    t.string "blockchain_tx_hash"
    t.string "funding_source", default: "moncash", null: false
    t.string "payout_method"
    t.string "receiver_cashtag"
    t.string "receiver_bank_account"
    t.string "receiver_bank_name", default: "UNIBANK"
    t.string "receiver_account_holder"
    t.bigint "business_id"
    t.decimal "subtotal", precision: 12, scale: 2
    t.decimal "tax_amount", precision: 12, scale: 2
    t.index ["business_id"], name: "index_transfers_on_business_id"
    t.index ["status"], name: "index_transfers_on_status"
    t.index ["token"], name: "index_transfers_on_token", unique: true
    t.index ["user_id"], name: "index_transfers_on_user_id"
  end

  create_table "treasury_sweeps", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "asset", null: false
    t.decimal "amount", precision: 18, scale: 8, null: false
    t.string "from_address", null: false
    t.string "to_address", null: false
    t.string "gas_funding_tx_hash"
    t.string "sweep_tx_hash"
    t.string "status", default: "pending", null: false
    t.string "failure_reason"
    t.integer "confirmation_attempts", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_treasury_sweeps_on_status"
    t.index ["sweep_tx_hash"], name: "index_treasury_sweeps_on_sweep_tx_hash", unique: true, where: "(sweep_tx_hash IS NOT NULL)"
    t.index ["user_id", "asset", "status"], name: "index_treasury_sweeps_on_user_id_and_asset_and_status"
    t.index ["user_id"], name: "index_treasury_sweeps_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "credit_score", default: 0, null: false
    t.string "payout_preference", default: "auto", null: false
    t.string "transfer_pin_digest"
    t.datetime "transfer_pin_set_at"
    t.string "cashtag"
    t.string "phone_number"
    t.datetime "cashtag_changed_at"
    t.bigint "invited_by_id"
    t.boolean "auto_repay_enabled", default: false, null: false
    t.string "deposit_address"
    t.string "bonid"
    t.datetime "bonid_verified_at"
    t.string "bonid_first_name"
    t.string "bonid_last_name"
    t.string "bonid_photo_url"
    t.string "provider"
    t.string "uid"
    t.bigint "invite_code_id"
    t.string "bonid_street"
    t.string "bonid_locality"
    t.string "bonid_commune"
    t.string "bonid_department"
    t.string "bonid_country"
    t.string "bonid_blood_type"
    t.datetime "bonid_rechecked_at"
    t.index ["bonid"], name: "index_users_on_bonid", unique: true, where: "(bonid IS NOT NULL)"
    t.index ["cashtag"], name: "index_users_on_cashtag", unique: true
    t.index ["deposit_address"], name: "index_users_on_deposit_address", unique: true, where: "(deposit_address IS NOT NULL)"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["invite_code_id"], name: "index_users_on_invite_code_id"
    t.index ["phone_number"], name: "index_users_on_phone_number", unique: true, where: "(phone_number IS NOT NULL)"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true, where: "(provider IS NOT NULL)"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "wallet_ledger_entries", force: :cascade do |t|
    t.bigint "wallet_id", null: false
    t.bigint "user_id"
    t.string "entry_type", null: false
    t.decimal "amount", precision: 15, scale: 6, null: false
    t.decimal "balance_after", precision: 15, scale: 6, null: false
    t.string "reference_type"
    t.bigint "reference_id"
    t.string "moncash_transaction_id"
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "asset", default: "htg", null: false
    t.string "token", null: false
    t.index ["entry_type"], name: "index_wallet_ledger_entries_on_entry_type"
    t.index ["moncash_transaction_id"], name: "idx_wallet_ledger_moncash_tx_uniq", unique: true, where: "(moncash_transaction_id IS NOT NULL)"
    t.index ["reference_type", "reference_id"], name: "index_wallet_ledger_entries_on_reference_type_and_reference_id"
    t.index ["token"], name: "index_wallet_ledger_entries_on_token", unique: true
    t.index ["user_id"], name: "index_wallet_ledger_entries_on_user_id"
    t.index ["wallet_id", "asset", "created_at"], name: "idx_wallet_ledger_wallet_asset_created"
    t.index ["wallet_id", "created_at"], name: "index_wallet_ledger_entries_on_wallet_id_and_created_at"
    t.index ["wallet_id"], name: "index_wallet_ledger_entries_on_wallet_id"
  end

  create_table "wallets", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.decimal "htg_balance", precision: 15, scale: 2, default: "0.0", null: false
    t.integer "status", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "usdc_balance", precision: 15, scale: 6, default: "0.0", null: false
    t.decimal "eth_balance", precision: 18, scale: 8, default: "0.0", null: false
    t.decimal "wbtc_balance", precision: 18, scale: 8, default: "0.0", null: false
    t.decimal "tslax_balance", precision: 18, scale: 8, default: "0.0", null: false
    t.decimal "nvdax_balance", precision: 18, scale: 8, default: "0.0", null: false
    t.decimal "aaplx_balance", precision: 18, scale: 8, default: "0.0", null: false
    t.decimal "coinx_balance", precision: 18, scale: 8, default: "0.0", null: false
    t.decimal "googlx_balance", precision: 18, scale: 8, default: "0.0", null: false
    t.index ["user_id"], name: "index_wallets_on_user_id", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "bank_withdrawals", "users"
  add_foreign_key "bank_withdrawals", "wallet_ledger_entries"
  add_foreign_key "bank_withdrawals", "wallets"
  add_foreign_key "bonid_consent_requests", "transfers"
  add_foreign_key "bonid_consent_requests", "users"
  add_foreign_key "business_line_items", "products"
  add_foreign_key "business_line_items", "transfers"
  add_foreign_key "businesses", "users"
  add_foreign_key "invite_codes", "users", column: "creator_id"
  add_foreign_key "notifications", "users"
  add_foreign_key "notifications", "users", column: "actor_id"
  add_foreign_key "payment_methods", "users"
  add_foreign_key "payment_requests", "payment_methods"
  add_foreign_key "payment_requests", "sol_rounds"
  add_foreign_key "payment_requests", "users"
  add_foreign_key "payment_requests", "users", column: "payer_id"
  add_foreign_key "products", "businesses"
  add_foreign_key "sol_circles", "users"
  add_foreign_key "sol_contributions", "sol_rounds"
  add_foreign_key "sol_contributions", "transactions", column: "bank_transaction_id"
  add_foreign_key "sol_contributions", "users"
  add_foreign_key "sol_escrow_accounts", "sol_circles"
  add_foreign_key "sol_ledger_entries", "sol_escrow_accounts"
  add_foreign_key "sol_ledger_entries", "sol_rounds"
  add_foreign_key "sol_ledger_entries", "users"
  add_foreign_key "sol_memberships", "sol_circles"
  add_foreign_key "sol_memberships", "users"
  add_foreign_key "sol_rounds", "sol_circles"
  add_foreign_key "sol_rounds", "users", column: "payout_user_id"
  add_foreign_key "transactions", "users"
  add_foreign_key "transfers", "businesses"
  add_foreign_key "transfers", "users"
  add_foreign_key "treasury_sweeps", "users"
  add_foreign_key "users", "invite_codes"
  add_foreign_key "users", "users", column: "invited_by_id"
  add_foreign_key "wallet_ledger_entries", "users"
  add_foreign_key "wallet_ledger_entries", "wallets"
  add_foreign_key "wallets", "users"
end

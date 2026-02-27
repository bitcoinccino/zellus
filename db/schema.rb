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

ActiveRecord::Schema[8.0].define(version: 2026_02_27_100003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "exchange_rates", force: :cascade do |t|
    t.string "from_currency"
    t.string "to_currency"
    t.decimal "rate"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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
    t.index ["payment_method_id"], name: "index_payment_requests_on_payment_method_id"
    t.index ["sol_round_id"], name: "index_payment_requests_on_sol_round_id"
    t.index ["token"], name: "index_payment_requests_on_token", unique: true
    t.index ["user_id", "status"], name: "index_payment_requests_on_user_id_and_status"
    t.index ["user_id"], name: "index_payment_requests_on_user_id"
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
    t.index ["sol_circle_id"], name: "index_sol_memberships_on_sol_circle_id"
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
    t.index ["status"], name: "index_transfers_on_status"
    t.index ["token"], name: "index_transfers_on_token", unique: true
    t.index ["user_id"], name: "index_transfers_on_user_id"
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
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "wallet_ledger_entries", force: :cascade do |t|
    t.bigint "wallet_id", null: false
    t.bigint "user_id"
    t.string "entry_type", null: false
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.decimal "balance_after", precision: 15, scale: 2, null: false
    t.string "reference_type"
    t.bigint "reference_id"
    t.string "moncash_transaction_id"
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_type"], name: "index_wallet_ledger_entries_on_entry_type"
    t.index ["moncash_transaction_id"], name: "idx_wallet_ledger_moncash_tx_uniq", unique: true, where: "(moncash_transaction_id IS NOT NULL)"
    t.index ["reference_type", "reference_id"], name: "index_wallet_ledger_entries_on_reference_type_and_reference_id"
    t.index ["user_id"], name: "index_wallet_ledger_entries_on_user_id"
    t.index ["wallet_id", "created_at"], name: "index_wallet_ledger_entries_on_wallet_id_and_created_at"
    t.index ["wallet_id"], name: "index_wallet_ledger_entries_on_wallet_id"
  end

  create_table "wallets", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.decimal "htg_balance", precision: 15, scale: 2, default: "0.0", null: false
    t.integer "status", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_wallets_on_user_id", unique: true
  end

  add_foreign_key "payment_methods", "users"
  add_foreign_key "payment_requests", "payment_methods"
  add_foreign_key "payment_requests", "sol_rounds"
  add_foreign_key "payment_requests", "users"
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
  add_foreign_key "transfers", "users"
  add_foreign_key "wallet_ledger_entries", "users"
  add_foreign_key "wallet_ledger_entries", "wallets"
  add_foreign_key "wallets", "users"
end

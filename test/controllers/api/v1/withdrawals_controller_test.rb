require "test_helper"

class Api::V1::WithdrawalsControllerTest < ActionDispatch::IntegrationTest
  include ApiTestHelper

  setup do
    @sender = users(:sender)
    @token = oauth_tokens(:sender_full_access).access_token
    setup_transfer_pin!(@sender, "1234")
  end

  # ── MonCash withdrawal ──

  test "moncash withdrawal with valid params returns 201" do
    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    data = parsed_response
    assert data["success"]
    assert_equal "moncash", data.dig("withdrawal", "method")
    assert_equal "processing", data.dig("withdrawal", "status")
    assert_equal "htg", data.dig("withdrawal", "asset")
    assert data.dig("withdrawal", "reference").present?
  end

  test "moncash withdrawal debits wallet balance" do
    wallet = wallets(:sender_wallet)
    original_balance = wallet.htg_balance

    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    wallet.reload
    assert_operator wallet.htg_balance, :<, original_balance
  end

  test "moncash withdrawal with invalid phone returns 422" do
    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "123", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "MonCash"
  end

  test "moncash withdrawal below minimum returns 422" do
    post api_v1_withdrawals_url,
         params: { amount: 50, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "ant"
  end

  test "moncash withdrawal above maximum returns 422" do
    post api_v1_withdrawals_url,
         params: { amount: 60_000, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "ant"
  end

  test "moncash withdrawal with usd asset returns 422" do
    post api_v1_withdrawals_url,
         params: { amount: 50, asset: "usd", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "HTG"
  end

  # ── Bank withdrawal ──

  test "bank withdrawal with valid params returns 201" do
    post api_v1_withdrawals_url,
         params: {
           amount: 1000, asset: "htg", method: "bank",
           bank_account: "1234567890", account_holder: "Jean Test",
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :created
    data = parsed_response
    assert data["success"]
    assert_equal "bank", data.dig("withdrawal", "method")
    assert_equal "processing", data.dig("withdrawal", "status")
  end

  test "bank withdrawal creates BankWithdrawal record" do
    assert_difference -> { BankWithdrawal.count }, 1 do
      post api_v1_withdrawals_url,
           params: {
             amount: 1000, asset: "htg", method: "bank",
             bank_account: "1234567890", account_holder: "Jean Test",
             pin: "1234"
           },
           headers: api_auth_headers(@token)
    end

    assert_response :created
  end

  test "bank withdrawal with missing bank_account returns 422" do
    post api_v1_withdrawals_url,
         params: { amount: 1000, asset: "htg", method: "bank", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "kont bank"
  end

  test "bank withdrawal below minimum returns 422" do
    post api_v1_withdrawals_url,
         params: {
           amount: 100, asset: "htg", method: "bank",
           bank_account: "1234567890", pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "ant"
  end

  # ── Crypto (USD) withdrawal ──

  test "crypto withdrawal with valid params returns 201" do
    post api_v1_withdrawals_url,
         params: {
           amount: 50, asset: "usd", method: "crypto",
           wallet_address: "0x" + "a1b2c3d4e5" * 4,
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :created
    data = parsed_response
    assert data["success"]
    assert_equal "crypto", data.dig("withdrawal", "method")
    assert_equal "usd", data.dig("withdrawal", "asset")
    assert_equal "processing", data.dig("withdrawal", "status")
  end

  test "crypto withdrawal with invalid wallet address returns 422" do
    post api_v1_withdrawals_url,
         params: {
           amount: 50, asset: "usd", method: "crypto",
           wallet_address: "not_a_valid_address",
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "adrès Base"
  end

  test "crypto withdrawal below minimum returns 422" do
    post api_v1_withdrawals_url,
         params: {
           amount: 0.5, asset: "usd", method: "crypto",
           wallet_address: "0x" + "a1b2c3d4e5" * 4,
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "ant"
  end

  test "crypto withdrawal above maximum returns 422" do
    post api_v1_withdrawals_url,
         params: {
           amount: 600, asset: "usd", method: "crypto",
           wallet_address: "0x" + "a1b2c3d4e5" * 4,
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "ant"
  end

  test "crypto withdrawal with htg asset returns 422" do
    post api_v1_withdrawals_url,
         params: {
           amount: 50, asset: "htg", method: "crypto",
           wallet_address: "0x" + "a1b2c3d4e5" * 4,
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "USD"
  end

  # ── Atomicity (pessimistic locking) ──

  test "withdrawal debits exact amount atomically via row lock" do
    wallet = wallets(:sender_wallet)
    wallet.update!(htg_balance: 5000)

    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    wallet.reload

    # Wallet balance should be original minus the full 500 (payout + fee)
    assert_operator wallet.htg_balance, :<, BigDecimal("5000")
    assert_operator wallet.htg_balance, :>=, 0
  end

  test "withdrawal creates ledger entries with balance_after matching wallet" do
    wallet = wallets(:sender_wallet)
    wallet.update!(htg_balance: 2000)

    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    wallet.reload

    last_entry = wallet.wallet_ledger_entries.order(:created_at).last
    assert_equal wallet.htg_balance, last_entry.balance_after,
                 "Ledger balance_after doesn't match wallet balance — atomicity issue"
  end

  test "concurrent withdrawals cannot overdraw wallet" do
    wallet = wallets(:sender_wallet)
    wallet.update!(htg_balance: 600)

    results = []
    2.times do
      begin
        post api_v1_withdrawals_url,
             params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
             headers: api_auth_headers(@token)
        results << response.status
      rescue => e
        results << e.class.name
      end
    end

    success_count = results.count(201)
    assert_operator success_count, :<=, 1, "Double-spend detected: both withdrawals succeeded"

    wallet.reload
    assert_operator wallet.htg_balance, :>=, 0, "Balance went negative — atomicity broken"
  end

  # ── Rate limiting ──

  test "returns 429 when withdrawal rate limit is exceeded" do
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # Withdrawal endpoint has limit: 10
    11.times do
      post api_v1_withdrawals_url,
           params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
           headers: api_auth_headers(@token)
    end

    assert_response :too_many_requests
    assert_includes parsed_response["error"], "Twòp demann"
  ensure
    Rails.cache = original_store
  end

  # ── JSON schema ──

  test "moncash withdrawal response matches expected JSON schema" do
    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    data = parsed_response
    assert_json_includes_keys data, %w[success withdrawal]
    assert_json_keys data["withdrawal"], %w[reference amount fee payout asset method status]
  end

  test "bank withdrawal response matches expected JSON schema" do
    post api_v1_withdrawals_url,
         params: {
           amount: 1000, asset: "htg", method: "bank",
           bank_account: "1234567890", account_holder: "Jean Test",
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :created
    data = parsed_response
    assert_json_includes_keys data, %w[success withdrawal]
    assert_json_keys data["withdrawal"], %w[reference amount fee payout asset method status]
  end

  test "crypto withdrawal response matches expected JSON schema" do
    post api_v1_withdrawals_url,
         params: {
           amount: 50, asset: "usd", method: "crypto",
           wallet_address: "0x" + "a1b2c3d4e5" * 4,
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :created
    data = parsed_response
    assert_json_includes_keys data, %w[success withdrawal]
    assert_json_keys data["withdrawal"], %w[reference amount fee payout asset method status]
  end

  # ── PIN failures ──

  test "returns 401 with wrong PIN" do
    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "9999" },
         headers: api_auth_headers(@token)

    assert_response :unauthorized
    assert_includes parsed_response["error"], "PIN"
  end

  # ── Scope failures ──

  test "returns 403 without withdraw:create scope" do
    readonly_token = oauth_tokens(:sender_readonly).access_token

    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(readonly_token)

    assert_response :forbidden
    assert_includes parsed_response["error"], "withdraw:create"
  end

  # ── Insufficient balance ──

  test "returns 422 with insufficient htg balance" do
    wallets(:sender_wallet).update!(htg_balance: 50)

    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "Balans"
  end

  test "returns 422 with insufficient usd balance" do
    wallets(:sender_wallet).update!(usdc_balance: 0)

    post api_v1_withdrawals_url,
         params: {
           amount: 50, asset: "usd", method: "crypto",
           wallet_address: "0x" + "a1b2c3d4e5" * 4,
           pin: "1234"
         },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "Balans"
  end

  # ── Invalid method ──

  test "returns 422 with invalid withdrawal method" do
    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "paypal", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "Metòd"
  end
end

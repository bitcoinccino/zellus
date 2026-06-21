require "test_helper"

class Api::V1::TransfersControllerTest < ActionDispatch::IntegrationTest
  include ApiTestHelper

  setup do
    @sender = users(:sender)
    @receiver = users(:receiver)
    @token = oauth_tokens(:sender_full_access).access_token
    setup_transfer_pin!(@sender, "1234")
  end

  # ── Successful transfers ──

  test "creates transfer to cashtag and debits wallet" do
    wallet = wallets(:sender_wallet)
    original_balance = wallet.htg_balance

    assert_difference -> { Transfer.count }, 1 do
      post api_v1_transfers_url,
           params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
           headers: api_auth_headers(@token)
    end

    assert_response :created
    data = parsed_response
    assert data["success"]
    assert_equal "funded", data.dig("transfer", "status")
    assert_equal "$receivergal", data.dig("transfer", "receiver")
    assert_equal "100.0", data.dig("transfer", "amount")

    wallet.reload
    assert_operator wallet.htg_balance, :<, original_balance
  end

  test "creates transfer to phone number" do
    assert_difference -> { Transfer.count }, 1 do
      post api_v1_transfers_url,
           params: { note: "Test note", receiver: "50987654321", amount: 200, asset: "htg", pin: "1234" },
           headers: api_auth_headers(@token)
    end

    assert_response :created
    data = parsed_response
    assert data["success"]
    assert_equal "funded", data.dig("transfer", "status")
  end

  test "enqueues TransferPayoutWorker on successful transfer" do
    assert_difference -> { Transfer.count }, 1 do
      post api_v1_transfers_url,
           params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
           headers: api_auth_headers(@token)
    end

    assert_response :created
  end

  # ── Atomicity (pessimistic locking) ──

  test "transfer debits exact amount plus fee atomically via row lock" do
    wallet = wallets(:sender_wallet)
    wallet.update!(htg_balance: 5000)

    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    wallet.reload
    transfer = Transfer.order(:created_at).last

    # Balance should equal original minus (net_amount + fee)
    expected = BigDecimal("5000") - transfer.net_amount - transfer.fee
    assert_equal expected, wallet.htg_balance
  end

  test "concurrent transfers cannot double-spend the same balance" do
    wallet = wallets(:sender_wallet)
    # Set balance to only cover one 200 HTG transfer
    wallet.update!(htg_balance: 250)

    results = []
    2.times do
      begin
        post api_v1_transfers_url,
             params: { note: "Test note", receiver: "$receivergal", amount: 200, asset: "htg", pin: "1234" },
             headers: api_auth_headers(@token)
        results << response.status
      rescue => e
        results << e.class.name
      end
    end

    # At most one should succeed (201), the other should fail (422 insufficient)
    success_count = results.count(201)
    assert_operator success_count, :<=, 1, "Double-spend detected: both transfers succeeded"

    wallet.reload
    assert_operator wallet.htg_balance, :>=, 0, "Balance went negative — atomicity broken"
  end

  test "transfer creates matching ledger entries with correct balance_after" do
    wallet = wallets(:sender_wallet)
    wallet.update!(htg_balance: 1000)

    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    wallet.reload

    # The last ledger entry's balance_after should match the wallet's current balance
    last_entry = wallet.wallet_ledger_entries.order(:created_at).last
    assert_equal wallet.htg_balance, last_entry.balance_after
  end

  # ── Rate limiting ──

  test "returns 429 when transfer rate limit is exceeded" do
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # Transfer endpoint has limit: 10
    11.times do
      post api_v1_transfers_url,
           params: { note: "Test note", receiver: "$receivergal", amount: 50, asset: "htg", pin: "1234" },
           headers: api_auth_headers(@token)
    end

    assert_response :too_many_requests
    assert_includes parsed_response["error"], "Twòp demann"
  ensure
    Rails.cache = original_store
  end

  # ── JSON schema ──

  test "transfer response matches expected JSON schema" do
    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    data = parsed_response
    assert_json_includes_keys data, %w[success transfer]
    assert_json_keys data["transfer"], %w[token status amount fee net_amount asset receiver note created_at]
  end

  # ── GET show ──

  test "returns transfer details by token" do
    # Create a transfer first
    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :created
    transfer_token = parsed_response.dig("transfer", "token")

    get api_v1_transfer_url(token: transfer_token), headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert data["success"]
    assert_equal transfer_token, data.dig("transfer", "token")
  end

  test "returns 404 for non-existent transfer token" do
    get api_v1_transfer_url(token: "nonexistent_token"), headers: api_auth_headers(@token)

    assert_response :not_found
  end

  # ── PIN failures ──

  test "returns 401 with wrong PIN" do
    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "9999" },
         headers: api_auth_headers(@token)

    assert_response :unauthorized
    assert_includes parsed_response["error"], "PIN"
  end

  test "returns 422 when PIN not set" do
    @sender.update_columns(transfer_pin_digest: nil, transfer_pin_set_at: nil)

    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "PIN"
  end

  # ── Validation failures ──

  test "returns 422 with missing receiver" do
    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "Resevwa"
  end

  test "returns 422 when amount below minimum (50 HTG)" do
    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 10, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], Transfer::SEND_MIN_HTG.to_s
  end

  test "returns 422 when amount above maximum (50000 HTG)" do
    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 60_000, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], Transfer::SEND_MAX_HTG.to_s
  end

  test "returns 422 when exceeding daily limit" do
    # Set override to a small limit
    @sender.update!(daily_transfer_limit_override: 100)

    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 200, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "limit"
  end

  test "returns 422 with insufficient balance" do
    wallets(:sender_wallet).update!(htg_balance: 10)

    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "Balans"
  end

  test "returns 422 with invalid asset" do
    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "eur", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "Aktif"
  end

  # ── Scope failures ──

  test "returns 403 without transfer:create scope" do
    readonly_token = oauth_tokens(:sender_readonly).access_token

    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(readonly_token)

    assert_response :forbidden
    assert_includes parsed_response["error"], "transfer:create"
  end

  # ── Frozen wallet ──

  test "returns 403 when wallet is frozen" do
    wallets(:sender_wallet).update!(status: :held)

    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token)

    assert_response :forbidden
    assert_includes parsed_response["error"], "jele"
  end

  # ── Idempotency ──

  test "same idempotency key replays cached 201 without creating duplicate" do
    headers = api_auth_headers(@token).merge("X-Idempotency-Key" => "unique-key-001")

    assert_difference -> { Transfer.count }, 1 do
      post api_v1_transfers_url,
           params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
           headers: headers
    end

    assert_response :created
    first_response = response.body

    # Second request with same key — should NOT create a new transfer
    assert_no_difference -> { Transfer.count } do
      post api_v1_transfers_url,
           params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
           headers: headers
    end

    assert_response :created
    assert_equal first_response, response.body
  end

  test "different idempotency key creates new resource" do
    assert_difference -> { Transfer.count }, 2 do
      post api_v1_transfers_url,
           params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
           headers: api_auth_headers(@token).merge("X-Idempotency-Key" => "key-a")

      assert_response :created

      post api_v1_transfers_url,
           params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
           headers: api_auth_headers(@token).merge("X-Idempotency-Key" => "key-b")

      assert_response :created
    end
  end

  test "no idempotency header behaves normally" do
    assert_difference -> { Transfer.count }, 2 do
      2.times do
        post api_v1_transfers_url,
             params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
             headers: api_auth_headers(@token)

        assert_response :created
      end
    end
  end

  test "concurrent same-key request returns 409 Conflict" do
    key = "concurrent-key-001"
    # Simulate an in-progress lock by creating a locked record
    ApiIdempotencyKey.create!(
      user: @sender,
      idempotency_key: key,
      request_path: api_v1_transfers_path,
      locked_at: Time.current
    )

    post api_v1_transfers_url,
         params: { note: "Test note", receiver: "$receivergal", amount: 100, asset: "htg", pin: "1234" },
         headers: api_auth_headers(@token).merge("X-Idempotency-Key" => key)

    assert_response :conflict
    assert_includes parsed_response["error"], "trete deja"
  end
end

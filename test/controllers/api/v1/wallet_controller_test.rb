require "test_helper"

class Api::V1::WalletControllerTest < ActionDispatch::IntegrationTest
  include ApiTestHelper

  setup do
    @sender = users(:sender)
    @token = oauth_tokens(:sender_full_access).access_token
    @readonly_token = oauth_tokens(:sender_readonly).access_token
    @expired_token = oauth_tokens(:sender_expired).access_token
  end

  # ── Success ──

  test "returns wallet balances with valid token and balance:read scope" do
    get api_v1_wallet_url, headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert data["success"]
    assert_equal wallets(:sender_wallet).htg_balance.to_s, data.dig("wallet", "htg_balance")
    assert_equal wallets(:sender_wallet).usdc_balance.to_s, data.dig("wallet", "usd_balance")
    assert_equal "open", data.dig("wallet", "status")
  end

  test "returns wallet balances with readonly token" do
    get api_v1_wallet_url, headers: api_auth_headers(@readonly_token)

    assert_response :ok
    data = parsed_response
    assert data["success"]
    assert_includes data, "wallet"
  end

  test "includes business balances when user has a business" do
    business = Business.create!(
      user: @sender,
      name: "Ti Machann",
      slug: "ti-machann",
      category: "komes_manje",
      total_received: 10_000.0,
      usdc_balance: 50.0
    )

    get api_v1_wallet_url, headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert_equal "Ti Machann", data.dig("business", "name")
    assert_equal business.total_received.to_s, data.dig("business", "htg_balance")
  ensure
    business&.destroy
  end

  # ── Auth failures ──

  test "returns 401 with no auth header" do
    get api_v1_wallet_url

    assert_response :unauthorized
    assert_includes parsed_response["error"], "Otantifikasyon"
  end

  test "returns 401 with invalid token" do
    get api_v1_wallet_url, headers: api_auth_headers("bogus_token_xyz")

    assert_response :unauthorized
    assert_includes parsed_response["error"], "envalid"
  end

  test "returns 401 with expired token" do
    get api_v1_wallet_url, headers: api_auth_headers(@expired_token)

    assert_response :unauthorized
  end

  # ── Scope failures ──

  test "returns 403 when token lacks balance:read scope" do
    # Use a token that only has transfer:create scope
    full_token = oauth_tokens(:sender_full_access)
    full_token.update!(scopes: "transfer:create")

    get api_v1_wallet_url, headers: api_auth_headers(full_token.access_token)

    assert_response :forbidden
    assert_includes parsed_response["error"], "balance:read"
  end

  # ── Rate limiting ──

  test "returns 429 when rate limit is exceeded" do
    # Swap in memory store so cache.increment actually works
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # Wallet endpoint has limit: 60
    61.times do
      get api_v1_wallet_url, headers: api_auth_headers(@token)
    end

    assert_response :too_many_requests
    assert_includes parsed_response["error"], "Twòp demann"
  ensure
    Rails.cache = original_store
  end

  # ── JSON schema ──

  test "wallet response matches expected JSON schema" do
    get api_v1_wallet_url, headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert_json_includes_keys data, %w[success wallet]
    assert_json_keys data["wallet"], %w[htg_balance usd_balance status]
  end

  # ── No wallet ──

  test "returns 404 when user has no wallet" do
    receiver_token = oauth_tokens(:receiver_full_access)
    # Temporarily destroy receiver's wallet
    wallets(:receiver_wallet).destroy

    get api_v1_wallet_url, headers: api_auth_headers(receiver_token.access_token)

    assert_response :not_found
    assert_includes parsed_response["error"], "Pòtfèy"
  end
end

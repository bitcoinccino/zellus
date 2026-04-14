require "test_helper"

class Api::V1::TransactionsControllerTest < ActionDispatch::IntegrationTest
  include ApiTestHelper

  setup do
    @sender = users(:sender)
    @token = oauth_tokens(:sender_full_access).access_token
  end

  # ── Success ──

  test "returns paginated ledger entries with valid token and transactions:read scope" do
    get api_v1_transactions_url, headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert data["success"]
    assert_kind_of Array, data["transactions"]
    assert_operator data["transactions"].size, :>, 0
    assert_equal 1, data.dig("meta", "page")
    assert_equal 25, data.dig("meta", "per_page")
    assert_operator data.dig("meta", "total"), :>, 0
  end

  test "entries are ordered by created_at desc (recent first)" do
    get api_v1_transactions_url, headers: api_auth_headers(@token)

    assert_response :ok
    txns = parsed_response["transactions"]
    dates = txns.map { |t| Time.iso8601(t["created_at"]) }
    assert_equal dates, dates.sort.reverse
  end

  test "each entry has expected fields" do
    get api_v1_transactions_url, headers: api_auth_headers(@token)

    assert_response :ok
    entry = parsed_response["transactions"].first
    %w[id entry_type amount asset balance_after description created_at].each do |field|
      assert_includes entry.keys, field, "Missing field: #{field}"
    end
  end

  # ── Filters ──

  test "filters by asset=htg" do
    get api_v1_transactions_url, params: { asset: "htg" }, headers: api_auth_headers(@token)

    assert_response :ok
    txns = parsed_response["transactions"]
    assert_operator txns.size, :>, 0
    txns.each { |t| assert_equal "htg", t["asset"] }
  end

  test "filters by asset=usd" do
    get api_v1_transactions_url, params: { asset: "usd" }, headers: api_auth_headers(@token)

    assert_response :ok
    txns = parsed_response["transactions"]
    assert_operator txns.size, :>, 0
    txns.each { |t| assert_equal "usd", t["asset"] }
  end

  test "filters by type=deposit" do
    get api_v1_transactions_url, params: { type: "deposit" }, headers: api_auth_headers(@token)

    assert_response :ok
    txns = parsed_response["transactions"]
    assert_operator txns.size, :>, 0
    txns.each { |t| assert_equal "deposit", t["entry_type"] }
  end

  test "filters by type=withdrawal" do
    get api_v1_transactions_url, params: { type: "withdrawal" }, headers: api_auth_headers(@token)

    assert_response :ok
    txns = parsed_response["transactions"]
    assert_operator txns.size, :>, 0
    txns.each { |t| assert_equal "withdrawal", t["entry_type"] }
  end

  test "filters by since date" do
    since = 2.days.ago.iso8601
    get api_v1_transactions_url, params: { since: since }, headers: api_auth_headers(@token)

    assert_response :ok
    txns = parsed_response["transactions"]
    txns.each do |t|
      assert_operator Time.iso8601(t["created_at"]), :>=, Time.iso8601(since)
    end
  end

  test "filters by until date" do
    until_date = 1.day.ago.iso8601
    get api_v1_transactions_url, params: { until: until_date }, headers: api_auth_headers(@token)

    assert_response :ok
    txns = parsed_response["transactions"]
    txns.each do |t|
      assert_operator Time.iso8601(t["created_at"]), :<=, Time.iso8601(until_date)
    end
  end

  test "filters by since and until date range" do
    since_date = 3.days.ago.iso8601
    until_date = 1.day.ago.iso8601

    get api_v1_transactions_url,
        params: { since: since_date, until: until_date },
        headers: api_auth_headers(@token)

    assert_response :ok
    txns = parsed_response["transactions"]
    txns.each do |t|
      ts = Time.iso8601(t["created_at"])
      assert_operator ts, :>=, Time.iso8601(since_date)
      assert_operator ts, :<=, Time.iso8601(until_date)
    end
  end

  # ── Pagination ──

  test "paginates with custom page and per_page" do
    get api_v1_transactions_url, params: { page: 1, per_page: 2 }, headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert_equal 1, data.dig("meta", "page")
    assert_equal 2, data.dig("meta", "per_page")
    assert_operator data["transactions"].size, :<=, 2
  end

  test "per_page is capped at 100" do
    get api_v1_transactions_url, params: { per_page: 200 }, headers: api_auth_headers(@token)

    assert_response :ok
    assert_equal 100, parsed_response.dig("meta", "per_page")
  end

  test "defaults per_page to 25 when invalid" do
    get api_v1_transactions_url, params: { per_page: -1 }, headers: api_auth_headers(@token)

    assert_response :ok
    assert_equal 25, parsed_response.dig("meta", "per_page")
  end

  # ── Rate limiting ──

  test "returns 429 when rate limit is exceeded" do
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # Transactions endpoint has limit: 60
    61.times do
      get api_v1_transactions_url, headers: api_auth_headers(@token)
    end

    assert_response :too_many_requests
    assert_includes parsed_response["error"], "Twòp demann"
  ensure
    Rails.cache = original_store
  end

  # ── JSON schema ──

  test "transaction entry matches expected JSON schema" do
    get api_v1_transactions_url, headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert_json_includes_keys data, %w[success transactions meta]
    assert_json_keys data["meta"], %w[page per_page total]

    entry = data["transactions"].first
    assert_json_includes_keys entry, %w[id entry_type amount asset balance_after description created_at]
  end

  # ── Scope failures ──

  test "returns 403 without transactions:read scope" do
    readonly_token = oauth_tokens(:sender_readonly).access_token
    get api_v1_transactions_url, headers: api_auth_headers(readonly_token)

    assert_response :forbidden
    assert_includes parsed_response["error"], "transactions:read"
  end

  # ── No wallet ──

  test "returns empty response when user has no wallet" do
    receiver_token = oauth_tokens(:receiver_full_access)
    wallets(:receiver_wallet).destroy

    get api_v1_transactions_url, headers: api_auth_headers(receiver_token.access_token)

    assert_response :ok
    data = parsed_response
    assert data["success"]
    assert_equal [], data["transactions"]
    assert_equal 0, data.dig("meta", "total")
  end
end

require "test_helper"

class Api::V1::CheckoutsControllerTest < ActionDispatch::IntegrationTest
  include ApiTestHelper

  setup do
    @sender = users(:sender)
    @receiver = users(:receiver)
    @token = oauth_tokens(:sender_full_access).access_token

    # Sender will be the payer, receiver gets the checkout funds
    @sender_wallet = wallets(:sender_wallet)
    @receiver_wallet = wallets(:receiver_wallet)
  end

  # ── Create ──

  test "creates a checkout session" do
    assert_difference -> { CheckoutSession.count }, 1 do
      post api_v1_checkouts_url,
           params: { receiver_cashtag: "$receivergal", amount: 200, currency: "htg", success_url: "https://example.com/ok" },
           headers: api_auth_headers(@token)
    end

    assert_response :created
    data = parsed_response
    assert data["success"]
    assert_equal "pending", data.dig("checkout", "status")
    assert_equal "200.0", data.dig("checkout", "amount")
  end

  test "returns 422 with missing receiver_cashtag" do
    post api_v1_checkouts_url,
         params: { amount: 200, currency: "htg", success_url: "https://example.com/ok" },
         headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
  end

  # ── Show ──

  test "returns checkout by token" do
    checkout = create_completed_checkout!

    get api_v1_checkout_url(token: checkout.token), headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert data["success"]
    assert_equal checkout.token, data.dig("checkout", "token")
  end

  test "returns 404 for non-existent token" do
    get api_v1_checkout_url(token: "nope"), headers: api_auth_headers(@token)
    assert_response :not_found
  end

  # ── Refund (happy path) ──

  test "refunds a completed checkout" do
    checkout = create_completed_checkout!
    sender_before = @sender_wallet.reload.htg_balance
    receiver_before = @receiver_wallet.reload.htg_balance

    post api_v1_checkout_refund_url(token: checkout.token), headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert data["success"]
    assert_equal "refunded", data.dig("checkout", "status")
    assert_not_nil data.dig("checkout", "refunded_at")

    @sender_wallet.reload
    @receiver_wallet.reload

    assert_equal sender_before + checkout.amount, @sender_wallet.htg_balance
    assert_equal receiver_before - checkout.amount, @receiver_wallet.htg_balance

    checkout.reload
    assert checkout.refunded?
    assert_not_nil checkout.refunded_at
    assert checkout.transfer.refunded?
  end

  test "refund dispatches checkout.refunded webhook" do
    checkout = create_completed_checkout!

    assert_difference -> { WebhookDelivery.count }, 1 do
      post api_v1_checkout_refund_url(token: checkout.token), headers: api_auth_headers(@token)
    end

    assert_response :ok
    delivery = WebhookDelivery.order(:created_at).last
    assert_equal "checkout.refunded", delivery.event
  end

  # ── Refund (error cases) ──

  test "returns 404 for refund of non-existent checkout" do
    post api_v1_checkout_refund_url(token: "nonexistent"), headers: api_auth_headers(@token)
    assert_response :not_found
  end

  test "returns 422 when trying to refund a pending checkout" do
    checkout = CheckoutSession.create!(
      receiver_cashtag: "receivergal",
      amount: 100,
      currency: "htg",
      success_url: "https://example.com/ok",
      expires_at: 1.hour.from_now
    )

    post api_v1_checkout_refund_url(token: checkout.token), headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "konplete"
  end

  test "returns 422 when trying to refund an already refunded checkout" do
    checkout = create_completed_checkout!

    # Refund once
    post api_v1_checkout_refund_url(token: checkout.token), headers: api_auth_headers(@token)
    assert_response :ok

    # Try to refund again
    post api_v1_checkout_refund_url(token: checkout.token), headers: api_auth_headers(@token)
    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "konplete"
  end

  test "returns 422 when receiver has insufficient balance for refund" do
    checkout = create_completed_checkout!

    # Drain receiver wallet
    @receiver_wallet.update!(htg_balance: 0)

    post api_v1_checkout_refund_url(token: checkout.token), headers: api_auth_headers(@token)

    assert_response :unprocessable_entity
    assert_includes parsed_response["error"], "balans"
  end

  test "returns 403 without checkout:create scope" do
    checkout = create_completed_checkout!
    readonly_token = oauth_tokens(:sender_readonly).access_token

    post api_v1_checkout_refund_url(token: checkout.token), headers: api_auth_headers(readonly_token)

    assert_response :forbidden
    assert_includes parsed_response["error"], "checkout:create"
  end

  # ── Refund response schema ──

  test "refund response includes expected fields" do
    checkout = create_completed_checkout!

    post api_v1_checkout_refund_url(token: checkout.token), headers: api_auth_headers(@token)

    assert_response :ok
    data = parsed_response
    assert_json_includes_keys data["checkout"], %w[token status amount currency refunded_at]
  end

  private

  # Helper: creates a completed checkout with proper wallet movements
  def create_completed_checkout!
    amount = BigDecimal("200")

    # Create the transfer (sender -> receiver)
    transfer = Transfer.create!(
      user: @sender,
      token: "tf_test_#{SecureRandom.hex(4)}",
      status: :completed,
      amount: amount,
      fee: 0,
      net_amount: amount,
      asset: :htg,
      receiver_cashtag: "receivergal"
    )

    # Simulate wallet movements: debit sender, credit receiver
    @sender_wallet.update!(htg_balance: @sender_wallet.htg_balance - amount)
    @receiver_wallet.update!(htg_balance: @receiver_wallet.htg_balance + amount)

    CheckoutSession.create!(
      oauth_client: oauth_clients(:zellus_partner),
      payer: @sender,
      transfer: transfer,
      receiver_cashtag: "receivergal",
      amount: amount,
      currency: "htg",
      status: :completed,
      completed_at: Time.current,
      success_url: "https://example.com/ok",
      expires_at: 1.hour.from_now
    )
  end
end

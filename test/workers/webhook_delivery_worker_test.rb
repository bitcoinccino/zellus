require "test_helper"

class WebhookDeliveryWorkerTest < ActiveSupport::TestCase
  setup do
    @delivery = webhook_deliveries(:pending_delivery)
    @partner = oauth_clients(:zellus_partner)
  end

  test "successful delivery marks record as delivered" do
    mock_faraday_post(status: 200, body: '{"ok":true}') do
      WebhookDeliveryWorker.new.perform(@delivery.id)
    end

    @delivery.reload
    assert_equal "delivered", @delivery.status
    assert_equal 200, @delivery.response_status
    assert_not_nil @delivery.delivered_at
  end

  test "failed delivery increments attempts and sets next_retry_at" do
    mock_faraday_post(status: 500, body: "Internal Server Error") do
      WebhookDeliveryWorker.new.perform(@delivery.id)
    end

    @delivery.reload
    assert_equal "pending", @delivery.status
    assert_equal 1, @delivery.attempts
    assert_equal 500, @delivery.response_status
    assert_not_nil @delivery.next_retry_at
  end

  test "max attempts marks record as failed" do
    @delivery.update!(attempts: WebhookDelivery::MAX_ATTEMPTS - 1)

    mock_faraday_post(status: 500, body: "Server Error") do
      WebhookDeliveryWorker.new.perform(@delivery.id)
    end

    @delivery.reload
    assert_equal "failed", @delivery.status
    assert_equal WebhookDelivery::MAX_ATTEMPTS, @delivery.attempts
  end

  test "connection error marks as failed attempt" do
    mock_faraday_post(raise_error: Faraday::ConnectionFailed.new("connection refused")) do
      WebhookDeliveryWorker.new.perform(@delivery.id)
    end

    @delivery.reload
    assert_equal "pending", @delivery.status
    assert_equal 1, @delivery.attempts
    assert_equal 0, @delivery.response_status
  end

  test "HMAC signature is present in delivered webhook" do
    captured_headers = {}
    mock_faraday_post(status: 200, body: '{"ok":true}', capture_headers: captured_headers) do
      WebhookDeliveryWorker.new.perform(@delivery.id)
    end

    @delivery.reload
    assert_equal "delivered", @delivery.status
    assert captured_headers["X-Zellus-Signature"].present?, "Missing X-Zellus-Signature header"
    assert captured_headers["X-Zellus-Signature"].start_with?("sha256=")
    assert captured_headers["X-Zellus-Delivery"].present?
    assert captured_headers["X-Zellus-Event"].present?
    assert_equal @delivery.event, captured_headers["X-Zellus-Event"]
  end

  test "skips already-delivered records" do
    delivered = webhook_deliveries(:delivered_delivery)
    original_attempts = delivered.attempts

    WebhookDeliveryWorker.new.perform(delivered.id)

    delivered.reload
    assert_equal "delivered", delivered.status
    assert_equal original_attempts, delivered.attempts
  end

  test "skips if webhook_url is blank" do
    @partner.update_columns(webhook_url: nil)

    WebhookDeliveryWorker.new.perform(@delivery.id)

    @delivery.reload
    assert_equal "pending", @delivery.status
    assert_equal 0, @delivery.attempts
  end

  private

  FakeOptions = Struct.new(:timeout, :open_timeout)
  FakeRequest = Struct.new(:headers, :options, :body) do
    def initialize
      super({}, FakeOptions.new(nil, nil), nil)
    end
  end

  def mock_faraday_post(status: 200, body: "", raise_error: nil, capture_headers: nil, &block)
    fake_response = Struct.new(:status, :body).new(status, body)

    original_post = Faraday.method(:post)
    Faraday.define_singleton_method(:post) do |_url, &req_block|
      raise raise_error if raise_error

      req = FakeRequest.new
      req_block.call(req) if req_block
      capture_headers&.merge!(req.headers)

      fake_response
    end

    block.call
  ensure
    Faraday.define_singleton_method(:post, original_post)
  end
end

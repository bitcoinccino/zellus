require "test_helper"

class WebhookServiceTest < ActiveSupport::TestCase
  setup do
    @sender = users(:sender)
    @receiver = users(:receiver)
    @partner = oauth_clients(:zellus_partner)
    @readonly = oauth_clients(:readonly_partner)
  end

  test "dispatch creates WebhookDelivery for subscribed clients" do
    assert_difference -> { WebhookDelivery.count }, 1 do
      WebhookService.dispatch(
        "transfer.completed",
        user: @sender,
        payload: { token: "abc", amount: "100.0" }
      )
    end

    delivery = WebhookDelivery.order(:created_at).last
    assert_equal "transfer.completed", delivery.event
    assert_equal @partner.id, delivery.oauth_client_id
    assert_equal "pending", delivery.status
  end

  test "dispatch skips clients with webhook_active false" do
    # Deactivate zellus_partner's webhook so no deliveries should be created
    @partner.update!(webhook_active: false)

    assert_no_difference -> { WebhookDelivery.count } do
      WebhookService.dispatch(
        "transfer.completed",
        user: @sender,
        payload: { token: "abc", amount: "100.0" }
      )
    end
  end

  test "dispatch skips clients not subscribed to event" do
    # zellus_partner subscribes to transfer.* and withdrawal.* — not a made-up event
    assert_no_difference -> { WebhookDelivery.count } do
      WebhookService.dispatch(
        "nonexistent.event",
        user: @sender,
        payload: { data: "test" }
      )
    end
  end

  test "dispatch creates deliveries for receiver when they have an active token" do
    assert_difference -> { WebhookDelivery.count }, 1 do
      WebhookService.dispatch(
        "transfer.received",
        user: @receiver,
        payload: { token: "xyz", amount: "500.0" }
      )
    end

    delivery = WebhookDelivery.order(:created_at).last
    assert_equal "transfer.received", delivery.event
    assert_equal @partner.id, delivery.oauth_client_id
  end

  test "dispatch is a no-op for unknown events" do
    assert_no_difference -> { WebhookDelivery.count } do
      WebhookService.dispatch("unknown.event", user: @sender, payload: {})
    end
  end
end

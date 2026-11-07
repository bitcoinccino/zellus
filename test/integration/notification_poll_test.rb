require "test_helper"

class NotificationPollTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  teardown { Warden.test_reset! }

  test "poll returns what the fallback needs to chime and toast together" do
    user = users(:receiver)
    notification = Notification.create!(
      user: user,
      notification_type: "transfer_received",
      title: "$sender peye w 5.00 USD la"
    )
    user.transfer_pin = "4827"
    user.save!
    login_as(user, scope: :user)
    post login_pin_path, params: { pin: "4827" }

    get poll_notifications_path

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal notification.id, body["latest_sound_id"]
    assert_equal notification.title, body["latest_sound_title"]
  end
end

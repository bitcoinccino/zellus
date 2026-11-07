require "test_helper"

class NotificationServiceSoundTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @sender = users(:sender)
    @receiver = users(:receiver)
  end

  test "receiver chime is held until the crediting transaction commits" do
    during = nil
    after = capture_broadcasts(stream_for(@receiver)) do
      ActiveRecord::Base.transaction do
        receive_money
        during = broadcasts(stream_for(@receiver)).size
      end
    end

    assert_equal 0, during
    assert_equal 1, after.size
    assert_equal true, after.first["play_sound"]
    assert_equal latest_received_id, after.first["notification_id"]
  end

  test "no chime when the crediting transaction rolls back" do
    sent = capture_broadcasts(stream_for(@receiver)) do
      ActiveRecord::Base.transaction do
        receive_money
        raise ActiveRecord::Rollback
      end
    end

    assert_empty sent
  end

  test "sender is not chimed when their transfer completes" do
    sent = capture_broadcasts(stream_for(@sender)) do
      NotificationService.send(
        :create_notification,
        user: @sender,
        notification_type: "transfer_completed",
        title: "Ou peye"
      )
    end

    assert_equal 1, sent.size
    assert_equal false, sent.first["play_sound"]
  end

  test "chime and toast arrive in the same broadcast" do
    sent = capture_broadcasts(stream_for(@receiver)) { receive_money }

    assert_equal 1, sent.size
    assert_equal true, sent.first["play_sound"]
    assert_predicate sent.first["title"], :present?
  end

  private

  def receive_money
    NotificationService.uma_payment_received(@receiver, 5, "usd", "sender@uma")
  end

  def latest_received_id
    @receiver.notifications.where(notification_type: "transfer_received").maximum(:id)
  end

  def stream_for(user)
    NotificationChannel.broadcasting_for(user)
  end
end

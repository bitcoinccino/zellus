class WebhookDelivery < ApplicationRecord
  belongs_to :oauth_client

  MAX_ATTEMPTS = 5

  BACKOFF_SCHEDULE = [30.seconds, 2.minutes, 15.minutes, 1.hour, 4.hours].freeze

  scope :pending, -> { where(status: "pending") }
  scope :retriable, -> { pending.where("next_retry_at IS NULL OR next_retry_at <= ?", Time.current) }

  before_validation :set_delivery_id, on: :create

  validates :event, :delivery_id, :payload, presence: true

  def mark_delivered!(resp_status, resp_body)
    update!(
      status: "delivered",
      response_status: resp_status,
      response_body: resp_body.to_s.truncate(2000),
      delivered_at: Time.current
    )
  end

  def mark_failed_attempt!(resp_status, resp_body)
    new_attempts = attempts + 1
    if new_attempts >= MAX_ATTEMPTS
      update!(
        status: "failed",
        attempts: new_attempts,
        response_status: resp_status,
        response_body: resp_body.to_s.truncate(2000)
      )
    else
      backoff = BACKOFF_SCHEDULE[new_attempts - 1] || 4.hours
      update!(
        attempts: new_attempts,
        response_status: resp_status,
        response_body: resp_body.to_s.truncate(2000),
        next_retry_at: Time.current + backoff
      )
    end
  end

  private

  def set_delivery_id
    self.delivery_id ||= SecureRandom.uuid
  end
end

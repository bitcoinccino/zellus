# frozen_string_literal: true

require "faraday"

class WebhookDeliveryWorker
  include Sidekiq::Job
  sidekiq_options retry: 0 # We handle retries ourselves with exponential backoff

  def perform(delivery_id)
    delivery = WebhookDelivery.find_by(id: delivery_id)
    return unless delivery
    return unless delivery.status == "pending"

    client = delivery.oauth_client
    return unless client.webhook_active? && client.webhook_url.present?

    body = {
      event: delivery.event,
      delivery_id: delivery.delivery_id,
      timestamp: Time.current.iso8601,
      data: delivery.payload
    }.to_json

    signature = OpenSSL::HMAC.hexdigest(
      "SHA256",
      client.webhook_secret.to_s,
      body
    )

    begin
      response = Faraday.post(client.webhook_url) do |req|
        req.headers["Content-Type"] = "application/json"
        req.headers["X-Zellus-Signature"] = "sha256=#{signature}"
        req.headers["X-Zellus-Delivery"] = delivery.delivery_id
        req.headers["X-Zellus-Event"] = delivery.event
        req.options.timeout = 10
        req.options.open_timeout = 5
        req.body = body
      end

      if response.status.between?(200, 299)
        delivery.mark_delivered!(response.status, response.body)
      else
        delivery.mark_failed_attempt!(response.status, response.body)
        schedule_retry(delivery) if delivery.status == "pending"
      end
    rescue Faraday::Error, Errno::ECONNREFUSED, Timeout::Error => e
      delivery.mark_failed_attempt!(0, e.message)
      schedule_retry(delivery) if delivery.status == "pending"
    end
  end

  private

  def schedule_retry(delivery)
    return unless delivery.next_retry_at.present?

    delay = [ (delivery.next_retry_at - Time.current).to_i, 0 ].max
    WebhookDeliveryWorker.perform_in(delay.seconds, delivery.id)
  end
end

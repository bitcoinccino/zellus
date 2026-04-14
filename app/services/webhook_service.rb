class WebhookService
  EVENTS = %w[
    transfer.received
    transfer.completed
    transfer.failed
    withdrawal.completed
    withdrawal.failed
    checkout.completed
    checkout.refunded
  ].freeze

  class << self
    def dispatch(event, user:, payload:)
      return unless EVENTS.include?(event)

      # Find oauth_clients that subscribe to this event and are linked to this user
      client_ids = OauthToken.active
                             .where(user: user)
                             .select(:oauth_client_id)
                             .distinct

      clients = OauthClient.with_webhook(event).where(id: client_ids)

      clients.find_each do |client|
        delivery = client.webhook_deliveries.create!(
          event: event,
          payload: payload
        )
        WebhookDeliveryWorker.perform_async(delivery.id)
      end
    rescue => e
      Rails.logger.error "WebhookService.dispatch error [event=#{event}]: #{e.message}"
    end
  end
end

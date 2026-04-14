# frozen_string_literal: true

class IdempotencyCleanupWorker
  include Sidekiq::Job

  def perform
    deleted = ApiIdempotencyKey.expired.delete_all
    Rails.logger.info "IdempotencyCleanup: deleted #{deleted} expired keys"
  end
end

class ApiIdempotencyKey < ApplicationRecord
  belongs_to :user

  validates :idempotency_key, presence: true

  scope :expired, -> { where("created_at < ?", 24.hours.ago) }
end

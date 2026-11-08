class CheckoutSession < ApplicationRecord
  belongs_to :oauth_client, optional: true
  belongs_to :payer, class_name: "User", optional: true
  belongs_to :transfer, optional: true

  enum :status, { pending: "pending", completed: "completed", expired: "expired", canceled: "canceled", refunded: "refunded" }

  before_validation :ensure_token

  validates :token, presence: true, uniqueness: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true, inclusion: { in: %w[htg usd] }
  validates :success_url, presence: true
  validates :receiver_cashtag, presence: true
  validates :expires_at, presence: true

  def to_param
    token
  end

  def receiver_user
    User.find_by("LOWER(cashtag) = ?", receiver_cashtag.to_s.delete_prefix("$").downcase)
  end

  def expired_now?
    expires_at.present? && expires_at < Time.current
  end

  def time_until_expiry
    return nil if expires_at.blank?
    expires_at - Time.current
  end

  def expires_soon?
    pending? && time_until_expiry.present? && time_until_expiry <= 10.minutes
  end

  def expiry_countdown_label
    return "Ekspire" if expired_now?

    remaining = time_until_expiry.to_i
    hours = remaining / 3600
    minutes = (remaining % 3600) / 60

    if hours > 0
      "#{hours}h #{minutes}m rete"
    else
      "#{[ minutes, 0 ].max}m rete"
    end
  end

  def mark_expired_if_needed!
    return false unless pending? && expired_now?
    update!(status: :expired)
    true
  end

  private

  def ensure_token
    self.token ||= loop do
      candidate = SecureRandom.urlsafe_base64(12)
      break candidate unless self.class.exists?(token: candidate)
    end
  end
end

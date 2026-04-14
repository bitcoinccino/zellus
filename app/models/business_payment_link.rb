class BusinessPaymentLink < ApplicationRecord
  belongs_to :business

  enum :status, { active: "active", paid: "paid", expired: "expired", disabled: "disabled" }
  enum :asset, { htg: "htg", usd: "usd" }

  before_validation :ensure_token
  before_validation :compute_amount_from_items

  validates :token, presence: true, uniqueness: true
  validates :asset, presence: true
  validates :amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :note, length: { maximum: 280 }, allow_blank: true
  validate :validate_items_format

  scope :recent_first, -> { order(created_at: :desc) }
  scope :usable, -> { where(status: :active) }

  def to_param
    token
  end

  def reusable?
    !single_use
  end

  def open_amount?
    amount.nil? && items.blank?
  end

  def itemized?
    items.present? && items.is_a?(Array) && items.any?
  end

  def items_total
    return 0 unless itemized?
    items.sum { |i| (i["quantity"].to_i) * (i["unit_price"].to_f) }
  end

  def expired_now?
    expires_at.present? && expires_at < Time.current
  end

  def mark_expired_if_needed!
    return false unless active? && expired_now?
    update!(status: :expired)
    true
  end

  def record_payment!
    increment!(:times_paid)
    update!(status: :paid) if single_use?
  end

  def asset_label
    asset == "usd" ? "USD" : "HTG"
  end

  def shareable_url
    Rails.application.routes.url_helpers.public_payment_link_url(token, host: Rails.application.config.action_mailer.default_url_options&.dig(:host) || "zellus.app")
  end

  private

  def compute_amount_from_items
    if itemized?
      self.amount = items_total
    end
  end

  def validate_items_format
    return if items.blank?
    unless items.is_a?(Array) && items.all? { |i| i.is_a?(Hash) && i["name"].present? && i["unit_price"].to_f > 0 && i["quantity"].to_i > 0 }
      errors.add(:items, "gen yon fòma ki pa kòrèk")
    end
  end

  def ensure_token
    self.token ||= loop do
      candidate = "lp_" + SecureRandom.urlsafe_base64(9)
      break candidate unless self.class.exists?(token: candidate)
    end
  end
end

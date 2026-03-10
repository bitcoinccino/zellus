class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :notifiable, polymorphic: true, optional: true

  # ── Scopes ──
  scope :unread,       -> { where(read_at: nil) }
  scope :recent_first, -> { order(created_at: :desc) }

  # ── Validations ──
  validates :notification_type, :title, presence: true

  # ── Read / Unread ──
  def read?  = read_at.present?
  def unread? = read_at.nil?

  def mark_read!
    update!(read_at: Time.current) if unread?
  end

  # ── Icon per type ──
  ICON_MAP = {
    "transfer_received"          => "ri-hand-coin-fill",
    "transfer_completed"         => "ri-checkbox-circle-fill",
    "transfer_failed"            => "ri-close-circle-fill",
    "payment_request_received"   => "ri-mail-send-fill",
    "payment_request_paid"       => "ri-money-dollar-circle-fill",
    "payment_request_expired"    => "ri-timer-fill",
    "payment_request_canceled"   => "ri-close-circle-fill"
  }.freeze

  COLOR_MAP = {
    "transfer_received"          => { bg: "#f0fdf4", fg: "#166534" },
    "transfer_completed"         => { bg: "#f0fdf4", fg: "#166534" },
    "transfer_failed"            => { bg: "#fef2f2", fg: "#991b1b" },
    "payment_request_received"   => { bg: "rgba(197,160,89,0.15)", fg: "#C5A059" },
    "payment_request_paid"       => { bg: "#f0fdf4", fg: "#166534" },
    "payment_request_expired"    => { bg: "#fefce8", fg: "#854d0e" },
    "payment_request_canceled"   => { bg: "#fef2f2", fg: "#991b1b" }
  }.freeze

  def icon_class
    ICON_MAP[notification_type] || "ri-notification-3-line"
  end

  def icon_color_style
    colors = COLOR_MAP[notification_type] || { bg: "rgba(93,99,69,0.1)", fg: "#5D6345" }
    "background: #{colors[:bg]}; color: #{colors[:fg]};"
  end

  # ── URL to navigate when notification is clicked ──
  def url
    case notifiable_type
    when "Transfer"
      Rails.application.routes.url_helpers.transfer_path(notifiable) if notifiable
    when "PaymentRequest"
      Rails.application.routes.url_helpers.public_payment_request_path(notifiable.token) if notifiable
    else
      Rails.application.routes.url_helpers.wallet_path
    end
  rescue
    Rails.application.routes.url_helpers.wallet_path
  end
end

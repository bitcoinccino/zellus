class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :notifiable, polymorphic: true, optional: true

  # ── Use short token in URLs ──
  before_create :generate_token

  def to_param
    token
  end

  # ── Scopes ──
  scope :unread,       -> { where(read_at: nil) }
  scope :recent_first, -> { order(created_at: :desc) }

  # ── Validations ──
  validates :notification_type, :title, presence: true

  # ── Display title (cleans up legacy business transfer titles) ──
  def display_title
    t = title.to_s
    if notifiable.is_a?(Transfer) && notifiable.business.present?
      # Old format: "$cashtag (Business Name) peye w ..." → "Business Name peye w ..."
      biz_name = notifiable.business.name
      t = t.sub(/\$\S+\s*\(#{Regexp.escape(biz_name)}\)/, biz_name)
    end
    t
  end

  # ── Read / Unread ──
  def read?  = read_at.present?
  def unread? = read_at.nil?

  def mark_read!
    update!(read_at: Time.current) if unread?
  end

  # ── Icon per type ──
  ICON_MAP = {
    "transfer_received"          => "ri-hand-coin-fill",
    "transfer_completed"         => "ri-send-plane-fill",
    "transfer_failed"            => "ri-close-circle-fill",
    "deposit_confirmed"          => "ri-arrow-down-circle-fill",
    "withdrawal_sent"            => "ri-arrow-up-circle-fill",
    "withdrawal_failed"          => "ri-close-circle-fill",
    "conversion_completed"       => "ri-exchange-funds-fill",
    "buy_completed"              => "ri-shopping-bag-fill",
    "sell_completed"             => "ri-exchange-dollar-fill",
    "buy_failed"                 => "ri-close-circle-fill",
    "payment_request_received"   => "ri-mail-send-fill",
    "payment_request_paid"       => "ri-money-dollar-circle-fill",
    "payment_request_expired"    => "ri-timer-fill",
    "payment_request_canceled"   => "ri-close-circle-fill",
    "payment_request_declined"   => "ri-forbid-2-fill",
    "thanks_received"            => "ri-heart-fill"
  }.freeze

  COLOR_MAP = {
    "transfer_received"          => { bg: "#f0fdf4", fg: "#166534" },
    "transfer_completed"         => { bg: "rgba(46,46,56,0.08)", fg: "var(--haiti-charcoal)" },
    "transfer_failed"            => { bg: "#fef2f2", fg: "#991b1b" },
    "deposit_confirmed"          => { bg: "#f0fdf4", fg: "#166534" },
    "withdrawal_sent"            => { bg: "rgba(46,46,56,0.08)", fg: "var(--haiti-charcoal)" },
    "withdrawal_failed"          => { bg: "#fef2f2", fg: "#991b1b" },
    "conversion_completed"       => { bg: "rgba(79,70,229,0.08)", fg: "#4f46e5" },
    "buy_completed"              => { bg: "rgba(46,46,56,0.08)", fg: "var(--haiti-charcoal)" },
    "sell_completed"             => { bg: "#f0fdf4", fg: "#166534" },
    "buy_failed"                 => { bg: "#fef2f2", fg: "#991b1b" },
    "payment_request_received"   => { bg: "rgba(197,160,89,0.15)", fg: "#C5A059" },
    "payment_request_paid"       => { bg: "#f0fdf4", fg: "#166534" },
    "payment_request_expired"    => { bg: "#fefce8", fg: "#854d0e" },
    "payment_request_canceled"   => { bg: "#fef2f2", fg: "#991b1b" },
    "payment_request_declined"   => { bg: "#fef2f2", fg: "#991b1b" },
    "thanks_received"            => { bg: "rgba(197,160,89,0.12)", fg: "#C5A059" }
  }.freeze

  def icon_class
    ICON_MAP[notification_type] || "ri-notification-3-line"
  end

  def icon_color_style
    colors = COLOR_MAP[notification_type] || { bg: "rgba(93,99,69,0.1)", fg: "#5D6345" }
    "background: #{colors[:bg]}; color: #{colors[:fg]};"
  end

  # ── Activity source (Pesonèl / Biznis / Ajan) ──
  def activity_source
    case notifiable_type
    when "AgentTransaction"
      "ajans"
    when "Business"
      # Agent application notifications (approved/rejected/suspended/reactivated)
      "ajans"
    when "Transfer"
      notifiable&.business_id.present? ? "biznis" : "pesonel"
    when "PaymentRequest"
      "pesonel"
    else
      "pesonel"
    end
  end

  # ── Activity category ──
  CATEGORY_MAP = {
    "transfer_received"          => "resevwa",
    "transfer_completed"         => "voye",
    "transfer_failed"            => "echwe",
    "deposit_confirmed"          => "depoze",
    "withdrawal_sent"            => "retire",
    "withdrawal_failed"          => "echwe",
    "conversion_completed"       => "konveti",
    "buy_completed"              => "achte",
    "sell_completed"             => "vann",
    "buy_failed"                 => "echwe",
    "payment_request_received"   => "demann",
    "payment_request_paid"       => "resevwa",
    "payment_request_expired"    => "demann",
    "payment_request_canceled"   => "echwe",
    "payment_request_declined"   => "echwe",
    "thanks_received"            => "mesi"
  }.freeze

  def activity_category
    CATEGORY_MAP[notification_type] || "voye"
  end

  # ── Creole sub-label per category ──
  LABEL_MAP = {
    "resevwa" => "↓ Resevwa",
    "depoze"  => "↓ Depoze",
    "voye"    => "↑ Voye",
    "retire"  => "↑ Retire",
    "achte"   => "↑ Achte",
    "vann"    => "↓ Vann",
    "konveti" => "⇄ Konvèti",
    "demann"  => "Demann",
    "echwe"   => "✕ Echwe",
    "mesi"    => "♥ Mèsi"
  }.freeze

  def activity_label
    LABEL_MAP[activity_category] || "↑ Voye"
  end

  # ── Color per category ──
  ACTIVITY_COLOR_MAP = {
    "resevwa" => "#166534",
    "depoze"  => "#166534",
    "vann"    => "#166534",
    "voye"    => "var(--haiti-charcoal)",
    "retire"  => "var(--haiti-charcoal)",
    "achte"   => "var(--haiti-charcoal)",
    "konveti" => "#4f46e5",
    "demann"  => "#C5A059",
    "echwe"   => "#991b1b",
    "mesi"    => "#C5A059"
  }.freeze

  def activity_color
    ACTIVITY_COLOR_MAP[activity_category] || "var(--haiti-charcoal)"
  end

  # ── Feed category helpers ──
  INCOMING_TYPES = %w[transfer_received deposit_confirmed sell_completed payment_request_received payment_request_paid thanks_received].freeze
  OUTGOING_TYPES = %w[transfer_completed transfer_failed withdrawal_sent withdrawal_failed buy_completed buy_failed conversion_completed payment_request_expired payment_request_canceled payment_request_declined].freeze

  def incoming?
    INCOMING_TYPES.include?(notification_type)
  end

  def outgoing?
    OUTGOING_TYPES.include?(notification_type)
  end

  # ── Currency icon for activity feed ──
  CURRENCY_BADGE_MAP = {
    "dollar"  => { label: "$",  icon: nil },
    "htg"     => { label: "G",  icon: nil },
    "eth"     => { label: nil,  icon: "ri-ethereum-fill" },
    "btc"     => { label: nil,  icon: "ri-bitcoin-fill" },
    "convert" => { label: "⇆", icon: nil }
  }.freeze

  def currency_icon_class
    t = title.to_s
    if t.include?("USD")
      "dollar"
    elsif t.include?("ETH")
      "eth"
    elsif t.include?("WBTC") || t.include?("BTC")
      "btc"
    elsif t.include?("konvèti") || t.include?("⇆")
      "convert"
    else
      "htg"
    end
  end

  def currency_badge_info
    CURRENCY_BADGE_MAP[currency_icon_class] || CURRENCY_BADGE_MAP["htg"]
  end

  # ── Amount extraction from title for right-side display ──
  def display_amount
    m = title.to_s.match(/(\d[\d,]*\.?\d*)\s*(HTG|USD|ETH|WBTC|TSLAX|NVDAX|AAPLX|COINX|GOOGLX)/i)
    return nil unless m

    raw    = m[1].delete(",")
    asset  = m[2].upcase
    number = BigDecimal(raw)

    # HTG → whole number with commas, everything else → 2 decimals
    formatted = if asset == "HTG"
                  number.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    else
                  "%.2f" % number
    end

    "#{formatted} #{asset}"
  end

  # ── Is this a success/positive notification? ──
  def success?
    %w[transfer_received transfer_completed deposit_confirmed withdrawal_sent conversion_completed buy_completed sell_completed payment_request_paid thanks_received].include?(notification_type)
  end

  def failed?
    %w[transfer_failed withdrawal_failed buy_failed].include?(notification_type)
  end

  def warning?
    %w[payment_request_expired payment_request_canceled payment_request_declined].include?(notification_type)
  end

  # ── Has this transfer_received notification been thanked? ──
  def thanked?
    return false unless notification_type == "transfer_received" && notifiable_type == "Transfer"

    Notification.exists?(
      notification_type: "thanks_received",
      actor_id: user_id,
      notifiable: notifiable
    )
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

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(12)
  end
end

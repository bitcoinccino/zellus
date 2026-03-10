class SolCircle < ApplicationRecord
  belongs_to :user
  has_many :sol_memberships, dependent: :destroy
  has_many :sol_rounds, dependent: :destroy
  has_many :users, through: :sol_memberships
  has_one :escrow_account, class_name: "SolEscrowAccount", dependent: :destroy

  enum :status, { pending: 0, active: 1, completed: 2 }
  enum :frequency, { three_months: 0, six_months: 1, twelve_months: 2 }
  enum :category, { fanmi: 0, kominote: 1, biznis: 2, ijans: 3, lekol: 4, agrikilti: 5, sante: 6, kay: 7, maryaj: 8, legliz: 9, vwayaj: 10, envestisman: 11 }

  CATEGORY_LABELS = {
    "fanmi" => "Fanmi",
    "kominote" => "Kominote",
    "biznis" => "Biznis",
    "ijans" => "Ijans",
    "lekol" => "Lekòl",
    "agrikilti" => "Agrikilti",
    "sante" => "Sante",
    "kay" => "Kay",
    "maryaj" => "Maryaj",
    "legliz" => "Legliz",
    "vwayaj" => "Vwayaj",
    "envestisman" => "Envestisman"
  }.freeze

  CATEGORY_ICONS = {
    "fanmi" => "ri-heart-line",
    "kominote" => "ri-community-line",
    "biznis" => "ri-store-2-line",
    "ijans" => "ri-first-aid-kit-line",
    "lekol" => "ri-graduation-cap-line",
    "agrikilti" => "ri-plant-line",
    "sante" => "ri-stethoscope-line",
    "kay" => "ri-home-4-line",
    "maryaj" => "ri-heart-2-line",
    "legliz" => "ri-building-4-line",
    "vwayaj" => "ri-flight-takeoff-line",
    "envestisman" => "ri-funds-line"
  }.freeze

  # Duration-based amount limits per asset
  DURATION_LIMITS = {
    "three_months"  => { htg_min: 1_000, htg_max: 50_000,  usdc_min: 1, usdc_max: 1_000 },
    "six_months"    => { htg_min: 1_000, htg_max: 150_000, usdc_min: 1, usdc_max: 2_000 },
    "twelve_months" => { htg_min: 1_000, htg_max: 500_000, usdc_min: 1, usdc_max: 5_000 }
  }.freeze

  validates :name, presence: true, length: { maximum: 60 }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :frequency, presence: true
  validates :target_members, presence: true, numericality: { in: 3..20 }
  validates :asset, presence: true, inclusion: { in: %w[htg usdc] }
  validates :platform_fee_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 5 }
  validates :creator_fee_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 5 }
  validate :enforce_duration_limits

  before_create :generate_token

  def total_rounds
    sol_memberships.active_members.count
  end

  def payout_amount
    amount * sol_memberships.active_members.count
  end

  # Net payout after platform + creator fees
  def net_payout_amount
    gross = payout_amount
    gross - platform_fee_amount - creator_fee_amount
  end

  def platform_fee_amount
    (payout_amount * platform_fee_percent / 100.0).round(2)
  end

  def creator_fee_amount
    (payout_amount * creator_fee_percent / 100.0).round(2)
  end

  # Total fee percentage (platform + creator)
  def total_fee_percent
    platform_fee_percent + creator_fee_percent
  end

  def full?
    sol_memberships.count >= target_members
  end

  def category_label
    CATEGORY_LABELS[category] || category&.titleize
  end

  def category_icon
    CATEGORY_ICONS[category] || "ri-loop-right-line"
  end

  STATUS_CONFIG = {
    "pending"   => { label: "Ap Tann Manm", icon: "ri-hourglass-line", bg: "#fefce8", color: "#854d0e", border: "#fde047" },
    "active"    => { label: "Aktif", icon: "ri-play-circle-line", bg: "#f0fdf4", color: "#166534", border: "#bbf7d0" },
    "completed" => { label: "Fini", icon: "ri-checkbox-circle-line", bg: "#f0f4ff", color: "#1e40af", border: "#bfdbfe" }
  }.freeze

  def status_label
    STATUS_CONFIG.dig(status, :label) || status&.titleize
  end

  def status_icon
    STATUS_CONFIG.dig(status, :icon) || "ri-question-line"
  end

  def status_bg
    STATUS_CONFIG.dig(status, :bg) || "#fff"
  end

  def status_color
    STATUS_CONFIG.dig(status, :color) || "#2E2E38"
  end

  def status_border
    STATUS_CONFIG.dig(status, :border) || "#ccc"
  end

  def htg?
    asset == "htg"
  end

  def usdc?
    asset == "usdc"
  end

  # Duration in months for display and round interval calculation
  def duration_months
    case frequency
    when "three_months" then 3
    when "six_months" then 6
    when "twelve_months" then 12
    end
  end

  def end_date
    return nil unless start_date
    start_date + duration_months.months
  end

  # Limits for this circle's duration
  def limits
    DURATION_LIMITS[frequency] || DURATION_LIMITS["six_months"]
  end

  def amount_range
    if htg?
      limits[:htg_min]..limits[:htg_max]
    else
      limits[:usdc_min]..limits[:usdc_max]
    end
  end

  # How often a round happens (in days)
  def round_interval_days
    total_days = duration_months * 30
    members = sol_memberships.active_members.count
    return 30 if members.zero?
    (total_days.to_f / members).round
  end

  private

  def enforce_duration_limits
    return unless frequency.present? && asset.present?

    lim = DURATION_LIMITS[frequency]
    return unless lim

    # Amount limits
    if amount.present?
      min_amt = htg? ? lim[:htg_min] : lim[:usdc_min]
      max_amt = htg? ? lim[:htg_max] : lim[:usdc_max]
      unit = htg? ? "HTG" : "USD"

      if amount < min_amt
        errors.add(:amount, "dwe omwen #{min_amt} #{unit} pou #{duration_months} mwa")
      end
      if amount > max_amt
        errors.add(:amount, "pa ka depase #{max_amt} #{unit} pou #{duration_months} mwa")
      end
    end
  end

  def generate_token
    self.token = SecureRandom.urlsafe_base64(10)
  end
end

class Business < ApplicationRecord
  belongs_to :user
  has_many :products, dependent: :destroy
  has_many :transfers # Incoming payments
  has_many :agent_transactions, dependent: :restrict_with_error
  has_many :payment_links, class_name: "BusinessPaymentLink", dependent: :destroy
  has_one_attached :logo
  has_one_attached :signage_photo

  # DB column is usdc_balance; alias to usd_balance for codebase consistency
  alias_attribute :usd_balance, :usdc_balance

  # ── Agent Scopes ──
  scope :agents, -> { where(is_agent: true) }
  scope :agent_pending, -> { where(agent_status: "pending") }

  delegate :cashtag, to: :user, prefix: :owner

  validates :name, :slug, presence: true, uniqueness: true
  validates :fee_rate, numericality: { greater_than_or_equal_to: 0 }
  validates :category, inclusion: { in: ->(_) { CATEGORIES.keys.map(&:to_s) } }, allow_nil: true
  validates :description, length: { maximum: 200 }, allow_blank: true
  validates :slug, format: { with: /\A[a-z0-9\-]+\z/, message: "selman let miniskil, chif, ak tire" }, allow_blank: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :logo_file_type_and_size

  before_validation :generate_slug, if: -> { slug.blank? && name.present? }
  before_save :auto_set_tippable, if: :category_changed?

  # The "Zèllus Advantage": Merchants can choose to auto-settle to USD
  enum :status, { pending: "pending", active: "active", suspended: "suspended" }

  # ── Master Categories (7) ──
  CATEGORIES = {
    sevis_dyaspora:      { label: "Sevis Dyaspora",              icon: "ri-plane-line" },
    sevis_debaz:         { label: "Sevis Debaz",                 icon: "ri-heart-pulse-line" },
    komes_manje:         { label: "Komes & Manje",               icon: "ri-store-2-line" },
    sevis_pesonel:       { label: "Sevis Pesonel",               icon: "ri-scissors-line" },
    pwofesyonel_finans:  { label: "Pwofesyonel & Finans",        icon: "ri-briefcase-line" },
    vwayaj_kominikasyon: { label: "Vwayaj & Kominikasyon",       icon: "ri-bus-line" },
    envestisman_dijital: { label: "Envestisman & Komes Dijital", icon: "ri-line-chart-line" }
  }.freeze

  # ── Subcategories ──
  SUBCATEGORIES = {
    sevis_dyaspora:      %w[remitans imigrasyon ekspedisyon_entenasyonal envestisman_dyaspora],
    sevis_debaz:         %w[dlo_kouran sante edikasyon enklizyon_finansye],
    komes_manje:         %w[sipemache kenkayri manje_sevis agrikilti mache],
    sevis_pesonel:       %w[bote antretyen evennman],
    pwofesyonel_finans:  %w[teknoloji legal prete sevis_biznis],
    vwayaj_kominikasyon: %w[telekom entenet transpo touris],
    envestisman_dijital: %w[jesyon_riches e_komes kripto_fintek ekonomi_gig]
  }.freeze

  SUBCATEGORY_LABELS = {
    # sevis_dyaspora
    "remitans"                  => "Remitans / Transfè",
    "imigrasyon"                => "Imigrasyon / Viza",
    "ekspedisyon_entenasyonal"  => "Ekspedisyon Entenasyonal",
    "envestisman_dyaspora"      => "Envestisman Dyaspora",
    # sevis_debaz
    "dlo_kouran"                => "Dlo / Kouran / Gaz",
    "sante"                     => "Sante / Famasi / Klinik",
    "edikasyon"                 => "Edikasyon / Lekol",
    "enklizyon_finansye"        => "Mikwofinans / Bank",
    # komes_manje
    "sipemache"                 => "Sipemache / Pwovizyon",
    "kenkayri"                  => "Kenkayri / Konstriksyon",
    "manje_sevis"               => "Restoran / Bakri / Manje",
    "agrikilti"                 => "Agrikilti / Kiltivasyon",
    "mache"                     => "Mache / Gwo Vant",
    # sevis_pesonel
    "bote"                      => "Salon Bote / Babe",
    "antretyen"                 => "Antretyen / Mekanisyen",
    "evennman"                  => "Evennman / Fotografi",
    # pwofesyonel_finans
    "teknoloji"                 => "Teknoloji / IT",
    "legal"                     => "Legal / Avoka",
    "prete"                     => "Prete / Mikwokredi",
    "sevis_biznis"              => "Kontab / Konsiltasyon",
    # vwayaj_kominikasyon
    "telekom"                   => "Telekom / Top-up",
    "entenet"                   => "Entenet / ISP",
    "transpo"                   => "Transpo / Livrezon",
    "touris"                    => "Touris / Otel",
    # envestisman_dijital
    "jesyon_riches"             => "Jesyon Riches / Epay",
    "e_komes"                   => "E-Komes / Boutik Anliyn",
    "kripto_fintek"             => "Kripto / Fintek",
    "ekonomi_gig"               => "Ekonomi Gig / Freelans"
  }.freeze

  # ── Tippable Subcategories ──
  # These subcategories auto-enable tips when merchant selects them
  TIPPABLE_SUBCATEGORIES = %w[
    manje_sevis
    bote
    transpo
    evennman
    ekonomi_gig
    touris
  ].freeze

  # ── Haiti Address Hierarchy (loaded from CSV-generated JSON) ──
  # Structure: Department → Arrondissement → Commune → [Communal Sections]
  # 10 departments, 42 arrondissements, 140 communes, 570 sections
  NESTED_ADDRESSES = JSON.parse(
    File.read(Rails.root.join("db/data/nested_addresses.json"), encoding: "utf-8")
  ).freeze

  # Convenience: flat department list for backward compat
  DEPARTMENTS = NESTED_ADDRESSES.transform_values { |arrs| arrs.values.flat_map(&:keys) }.freeze

  # ── Day-of-week mapping (Ruby wday → Creole key) ──
  WDAY_TO_CREOLE = %w[dimanch lendi madi mekredi jedi vandredi samdi].freeze

  # ── Helpers ──

  def open_now?
    parsed = begin; JSON.parse(hours.to_s); rescue; nil; end
    return false unless parsed.is_a?(Hash)
    day_key = WDAY_TO_CREOLE[Time.current.wday]
    day = parsed[day_key]
    return false unless day.is_a?(Hash) && day["open"].present? && day["close"].present?
    now = Time.current.strftime("%H:%M")
    now >= day["open"] && now <= day["close"]
  end

  def category_label
    CATEGORIES.dig(category&.to_sym, :label) || category&.titleize
  end

  def category_icon
    CATEGORIES.dig(category&.to_sym, :icon) || "ri-store-2-line"
  end

  def subcategory_label
    SUBCATEGORY_LABELS[subcategory] || subcategory&.titleize
  end

  def subcategories_for_category
    SUBCATEGORIES[category&.to_sym] || []
  end

  def tax_percentage
    (tax_rate.to_f * 100).round(1)
  end

  def total_fees_collected
    total_received * fee_rate
  end

  def increment_volume!(amount)
    increment!(:total_received, amount)
    increment!(:transaction_count)
  end

  # ── Balance helpers (for withdrawals) ──
  def htg_balance
    total_received.to_d
  end

  def sufficient_htg?(amount)
    htg_balance >= amount.to_d
  end

  def debit_htg!(amount)
    raise "Balans biznis pa sifi" unless sufficient_htg?(amount)
    with_lock do
      decrement!(:total_received, amount.to_d)
    end
  end

  def sufficient_usd?(amount)
    usd_balance.to_d >= amount.to_d
  end

  def debit_usd!(amount)
    raise "Balans USD biznis pa sifi" unless sufficient_usd?(amount)
    with_lock do
      decrement!(:usd_balance, amount.to_d)
    end
  end

  # ── Agent Network ──

  def agent?
    is_agent? && active?
  end

  def activate_agent!
    update!(is_agent: true, agent_activated_at: Time.current, agent_status: "approved")
  end

  def deactivate_agent!
    update!(is_agent: false, agent_status: "suspended")
  end

  def reactivate_agent!
    raise "Biznis pa sispann" unless agent_status == "suspended"

    update!(
      is_agent: true,
      agent_status: "approved",
      agent_activated_at: Time.current
    )
  end

  # ── Agent Application ──

  def agent_eligible?
    active? &&
      user&.bonid_verified? &&
      logo.attached? &&
      phone.present? &&
      department.present? &&
      commune.present?
  end

  def agent_eligibility_errors
    errs = []
    errs << "Biznis ou dwe aktif" unless active?
    errs << "BonID dwe verifye" unless user&.bonid_verified?
    errs << "Logo biznis obligatwa" unless logo.attached?
    errs << "Nimewo telefòn obligatwa" if phone.blank?
    errs << "Adrès fizik obligatwa (depatman + komin)" if department.blank? || commune.blank?
    errs
  end

  def can_apply_for_agent?
    agent_eligible? && agent_status == "none"
  end

  def agent_application_pending?
    agent_status == "pending"
  end

  def agent_application_rejected?
    agent_status == "rejected"
  end

  def apply_for_agent!
    raise "Biznis pa kalifye pou vin ajan" unless agent_eligible?
    raise "Aplikasyon deja soumèt" unless %w[none rejected].include?(agent_status)

    update!(
      agent_status: "pending",
      agent_applied_at: Time.current,
      agent_rejected_reason: nil
    )
  end

  def approve_agent!
    raise "Pa gen aplikasyon an atant" unless agent_status == "pending"

    update!(
      is_agent: true,
      agent_activated_at: Time.current,
      agent_status: "approved",
      agent_rejected_reason: nil
    )
  end

  def reject_agent!(reason:)
    raise "Pa gen aplikasyon an atant" unless agent_status == "pending"

    update!(
      agent_status: "rejected",
      agent_rejected_reason: reason
    )
  end

  def agent_float_htg
    total_received.to_d
  end

  def agent_float_sufficient?(amount)
    agent_float_htg >= amount.to_d
  end

  def today_cash_in_volume
    agent_transactions.cash_in.completed.today.sum(:amount)
  end

  def today_cash_in_count
    agent_transactions.cash_in.completed.today.count
  end

  def today_commission_earned
    agent_transactions.cash_in.completed.today.sum(:commission_amount)
  end

  # ── Tips ──

  def tippable_by_default?
    TIPPABLE_SUBCATEGORIES.include?(subcategory.to_s)
  end

  private

  def auto_set_tippable
    # Only auto-set if merchant hasn't manually toggled it
    # (new record or category just changed)
    if new_record? || !tippable_changed?
      self.tippable = tippable_by_default?
    end
  end

  def generate_slug
    base = name.parameterize
    candidate = base
    counter = 2
    while Business.where.not(id: id).exists?(slug: candidate)
      candidate = "#{base}-#{counter}"
      counter += 1
    end
    self.slug = candidate
  end

  def logo_file_type_and_size
    return unless logo.attached?
    unless logo.content_type.in?(%w[image/jpeg image/png image/webp image/svg+xml])
      errors.add(:logo, "dwe yon imaj (JPEG, PNG, WebP, SVG)")
    end
    if logo.byte_size > 2.megabytes
      errors.add(:logo, "pa ka depase 2MB")
    end
  end
end

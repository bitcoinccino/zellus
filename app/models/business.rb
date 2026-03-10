class Business < ApplicationRecord
  belongs_to :user
  has_many :products, dependent: :destroy
  has_many :transfers # Incoming payments
  has_one_attached :logo

  delegate :cashtag, to: :user, prefix: :owner

  validates :name, :slug, presence: true, uniqueness: true
  validates :fee_rate, numericality: { greater_than_or_equal_to: 0 }
  validates :category, inclusion: { in: ->(_) { CATEGORIES.keys.map(&:to_s) } }, allow_nil: true

  # The "Zellus Advantage": Merchants can choose to auto-settle to USD
  enum :status, { pending: "pending", active: "active", suspended: "suspended" }

  # ── Categories & Subcategories ──
  CATEGORIES = {
    lot:        { label: "Boutik / Magazen",   icon: "ri-store-2-line" },
    restoran:   { label: "Restoran / Manje",   icon: "ri-restaurant-line" },
    famasi:     { label: "Famasi",             icon: "ri-capsule-line" },
    lekol:      { label: "Lekòl / Edikasyon",  icon: "ri-graduation-cap-line" },
    sante:      { label: "Sante / Klinik",     icon: "ri-heart-pulse-line" },
    sevis:      { label: "Sèvis",              icon: "ri-tools-line" },
    agrikilti:  { label: "Agrikilti",          icon: "ri-plant-line" },
    transpo:    { label: "Transpò",            icon: "ri-taxi-line" },
    teknoloji:  { label: "Teknoloji",          icon: "ri-computer-line" },
    imobilye:   { label: "Imobilye / Kay",     icon: "ri-home-line" },
    mache:      { label: "Mache / Gwo Vant",   icon: "ri-shopping-cart-line" },
    lot_kateg:  { label: "Lòt",               icon: "ri-more-line" }
  }.freeze

  SUBCATEGORIES = {
    lot:        %w[rad elektwonik meb kosmetik jiwe kado],
    restoran:   %w[manje_rapid bar bakri kafe twaiteur],
    famasi:     %w[famasi_jeneral natirèl laboratwa],
    lekol:      %w[preskolè primè segondè inivesite fòmasyon],
    sante:      %w[klinik dantis optik lopital tèlmedsin],
    sevis:      %w[plonbye elektrisyen koutirye mekanisyen salon_bote legal kontab netwayaj],
    agrikilti:  %w[rekòt elvaj pwason semans ekipman],
    transpo:    %w[taksi moto kamyon livrezon],
    teknoloji:  %w[reparasyon lojisyèl akseswa entènèt],
    imobilye:   %w[lwaye vant konstriksyon],
    mache:      %w[manje_an_gwo materyèl twal],
    lot_kateg:  %w[lot]
  }.freeze

  SUBCATEGORY_LABELS = {
    # lot
    "rad" => "Rad / Chosèt", "elektwonik" => "Elektwonik", "meb" => "Mèb", "kosmetik" => "Kosmetik",
    "jiwe" => "Jiwe", "kado" => "Kado",
    # restoran
    "manje_rapid" => "Manje Rapid", "bar" => "Ba / Bwason", "bakri" => "Bakri / Pâtisri",
    "kafe" => "Kafe", "twaiteur" => "Twaitè",
    # famasi
    "famasi_jeneral" => "Famasi Jeneral", "natirèl" => "Pwodui Natirèl", "laboratwa" => "Laboratwa",
    # lekol
    "preskolè" => "Preskolè", "primè" => "Primè", "segondè" => "Segondè",
    "inivesite" => "Inivèsite", "fòmasyon" => "Fòmasyon Pwofesyonèl",
    # sante
    "klinik" => "Klinik", "dantis" => "Dantis", "optik" => "Optik",
    "lopital" => "Lopital", "tèlmedsin" => "Tèlmedsin",
    # sevis
    "plonbye" => "Plonbye", "elektrisyen" => "Elektrisyen", "koutirye" => "Koutirye",
    "mekanisyen" => "Mekanisyen", "salon_bote" => "Salon Bote", "legal" => "Legal",
    "kontab" => "Kontab", "netwayaj" => "Netwayaj",
    # agrikilti
    "rekòt" => "Rekòt / Jaden", "elvaj" => "Elvaj", "pwason" => "Pwason / Lapèch",
    "semans" => "Semans / Angrè", "ekipman" => "Ekipman",
    # transpo
    "taksi" => "Taksi", "moto" => "Mototaksi", "kamyon" => "Kamyon / Fret", "livrezon" => "Livrezon",
    # teknoloji
    "reparasyon" => "Reparasyon", "lojisyèl" => "Lojisyèl", "akseswa" => "Akseswa", "entènèt" => "Entènèt / WiFi",
    # imobilye
    "lwaye" => "Lwaye", "vant" => "Vant Pwopriyete", "konstriksyon" => "Konstriksyon",
    # mache
    "manje_an_gwo" => "Manje an Gwo", "materyèl" => "Materyèl", "twal" => "Twal / Tisi",
    # lot
    "lot" => "Lòt"
  }.freeze

  # ── Helpers ──

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
end

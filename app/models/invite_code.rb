class InviteCode < ApplicationRecord
  belongs_to :creator, class_name: "User"
  has_many :users

  # ── Location Data (from nested_addresses.json) ──
  NESTED_ADDRESSES = JSON.parse(
    File.read(Rails.root.join("db/data/nested_addresses.json"), encoding: "utf-8")
  ).freeze

  # Build flat list of all commune names for validation
  ALL_COMMUNES = NESTED_ADDRESSES.each_with_object([]) do |(dept, arrs), list|
    arrs.each do |arr, communes|
      communes.each_key { |commune| list << commune }
    end
  end.uniq.freeze

  # Legacy keys from old REGIONS hash for backward compatibility
  LEGACY_REGIONS = {
    "cotes_de_fer"   => "Côtes de Fer",
    "jacmel"         => "Jacmel",
    "port_au_prince" => "Port-au-Prince",
    "cap_haitien"    => "Cap-Haïtien",
    "les_cayes"      => "Les Cayes",
    "national"       => "Nasyonal"
  }.freeze

  VALID_REGIONS = (ALL_COMMUNES + LEGACY_REGIONS.keys + ["Nasyonal"]).freeze

  # ── Validations ──
  validates :code, presence: true, uniqueness: { case_sensitive: false }
  validates :region, presence: true, inclusion: { in: VALID_REGIONS }
  validates :max_uses, presence: true, numericality: { greater_than: 0 }

  # ── Scopes ──
  scope :active_codes, -> { where(active: true).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  # ── Callbacks ──
  before_validation :generate_code, on: :create, if: -> { code.blank? }
  before_validation :normalize_code

  # ── Can this code still be used? ──
  def available?
    active? && !expired? && !maxed_out?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def maxed_out?
    uses_count >= max_uses
  end

  def remaining_uses
    [max_uses - uses_count, 0].max
  end

  # ── Redeem: increment counter ──
  def redeem!
    raise "Kòd envitasyon sa a pa disponib ankò" unless available?
    increment!(:uses_count)
  end

  # ── Display ──
  def display_region
    LEGACY_REGIONS[region] || region
  end

  def to_s
    code
  end

  private

  def generate_code
    loop do
      # Format: XXX-XXXX (3-letter region prefix + 4 random chars)
      prefix = region_prefix
      self.code = "#{prefix}-#{SecureRandom.alphanumeric(4).upcase}"
      break unless InviteCode.exists?(code: code)
    end
  end

  def region_prefix
    # Legacy prefixes for backward compatibility
    legacy = {
      "cotes_de_fer" => "KDF", "jacmel" => "JAK", "port_au_prince" => "PAP",
      "cap_haitien" => "KAP", "les_cayes" => "OKY", "national" => "NAT"
    }
    return legacy[region] if legacy[region]

    # For commune names: use initials of each word (e.g. "Côtes de Fer" → "CDF")
    # Strip accents first, then take first letter of significant words
    clean = region.to_s
      .unicode_normalize(:nfkd)
      .gsub(/[^\x00-\x7F]/, "")

    words = clean.split(/[\s\-']+/).reject { |w| w.length <= 1 }
    initials = words.map { |w| w[0] }.join.upcase

    if initials.length >= 3
      initials[0, 3]
    elsif initials.length == 2
      # 2-word name: take first 2 letters of first word + first letter of second
      first_word = words.first.upcase
      initials = first_word[0, 2] + words.last[0].upcase
      initials[0, 3]
    else
      # Single word: take first 3 chars
      clean.gsub(/[^A-Za-z]/, "").upcase[0, 3].ljust(3, "X")
    end
  end

  def normalize_code
    self.code = code&.strip&.upcase
  end
end

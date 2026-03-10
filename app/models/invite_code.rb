class InviteCode < ApplicationRecord
  belongs_to :creator, class_name: "User"
  has_many :users

  # ── Regions ──
  REGIONS = {
    "cotes_de_fer" => "Côtes-de-Fer",
    "jacmel"       => "Jacmel",
    "port_au_prince" => "Pòtoprens",
    "cap_haitien"  => "Okap",
    "les_cayes"    => "Okay",
    "national"     => "Nasyonal"
  }.freeze

  # ── Validations ──
  validates :code, presence: true, uniqueness: { case_sensitive: false }
  validates :region, presence: true, inclusion: { in: REGIONS.keys }
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
    REGIONS[region] || region
  end

  def to_s
    code
  end

  private

  def generate_code
    loop do
      # Format: KDF-XXXX (region prefix + 4 random chars)
      prefix = case region
               when "cotes_de_fer" then "KDF"
               when "jacmel"       then "JAK"
               when "port_au_prince" then "PAP"
               when "cap_haitien"  then "KAP"
               when "les_cayes"    then "OKY"
               else "PRI"
               end
      self.code = "#{prefix}-#{SecureRandom.alphanumeric(4).upcase}"
      break unless InviteCode.exists?(code: code)
    end
  end

  def normalize_code
    self.code = code&.strip&.upcase
  end
end

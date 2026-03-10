class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :omniauthable, omniauth_providers: [:bonid]

  # Associations
  has_many :transactions, dependent: :destroy
  has_many :payment_methods, dependent: :destroy
  has_many :payment_requests, dependent: :destroy
  has_many :incoming_payment_requests, class_name: "PaymentRequest", foreign_key: :payer_id, dependent: :nullify
  has_many :sol_memberships, dependent: :destroy
  has_many :sol_circles, through: :sol_memberships
  has_many :transfers, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_one  :wallet, dependent: :destroy
  has_one  :business, dependent: :destroy
  has_many :sol_circles_created, class_name: "SolCircle", dependent: :nullify
  belongs_to :invited_by, class_name: "User", optional: true
  has_many :invitees, class_name: "User", foreign_key: :invited_by_id
  has_one_attached :avatar
  belongs_to :invite_code, optional: true

  # ── Invite Code ──
  attr_accessor :raw_invite_code
  validate :validate_invite_code, on: :create, if: -> { raw_invite_code.present? || !from_oauth? }

  # ── Cashtag ($username) ──
  CASHTAG_FORMAT = /\A[a-zA-Z0-9]{5,20}\z/
  INVITE_POINTS = 5

  before_validation :normalize_cashtag
  before_validation :resolve_invite_code, on: :create
  after_create :redeem_invite_code!

  validates :cashtag, presence: true,
            uniqueness: { case_sensitive: false },
            format: { with: CASHTAG_FORMAT, message: "dwe 5-20 karaktè alfanimerik" }

  validates :phone_number,
            format: { with: /\A509\d{8}\z/, message: "dwe fòma MonCash (509 + 8 chif)" },
            allow_blank: true,
            uniqueness: { allow_blank: true }

  validates :payout_preference, inclusion: { in: %w[auto htg usdc] }

  # ── Transfer PIN (4-digit, BCrypt-hashed) ──
  def transfer_pin=(raw_pin)
    require "bcrypt"
    if raw_pin.present?
      self.transfer_pin_digest = BCrypt::Password.create(raw_pin)
      self.transfer_pin_set_at = Time.current
    else
      self.transfer_pin_digest = nil
      self.transfer_pin_set_at = nil
    end
  end

  def transfer_pin_set?
    transfer_pin_digest.present?
  end

  def verify_transfer_pin(raw_pin)
    require "bcrypt"
    return false unless transfer_pin_digest.present? && raw_pin.present?

    BCrypt::Password.new(transfer_pin_digest) == raw_pin.to_s
  end

  # ── Wallet ──
  def wallet_balance
    wallet&.htg_balance || 0
  end

  def usdc_wallet_balance
    wallet&.usdc_balance || 0
  end

  def ensure_wallet!
    w = wallet || create_wallet!
    generate_deposit_address! if deposit_address.blank?
    w
  end

  def generate_deposit_address!
    addr = CryptoKeyHelper.derive_user_address(id)
    update_column(:deposit_address, addr) if addr.present?
  rescue => e
    Rails.logger.error "User#generate_deposit_address! failed for user=#{id}: #{e.message}"
  end

  # ── Daily Transfer Limit (~500 USD) ──
  DAILY_TRANSFER_LIMIT_HTG = 67_750

  def transfers_today_total
    transfers.where("created_at >= ?", Time.current.beginning_of_day)
             .where.not(status: %w[failed expired])
             .sum(:amount)
  end

  def daily_transfer_remaining
    [DAILY_TRANSFER_LIMIT_HTG - transfers_today_total, 0].max
  end

  # Payout preference: auto = use first available, htg = MonCash, usdc = Base wallet
  def prefers_usdc_payout?
    payout_preference == "usdc" || (payout_preference == "auto" && payment_methods.active.crypto_wallet.exists?)
  end

  def prefers_htg_payout?
    payout_preference == "htg" || (payout_preference == "auto" && !payment_methods.active.crypto_wallet.exists?)
  end

  # ── Auto-Repay Loans ──
  scope :auto_repay_enabled, -> { where(auto_repay_enabled: true) }

  MAX_CREDIT_SCORE = 800

  TIER_THRESHOLDS = {
    "Nouvo"   => 0,    # Unproven — no Sol history
    "Pijon"   => 100,  # Completed a clean 3-month Sol
    "Toutrèl" => 300,  # Consistent track record
    "Malfini" => 500,  # Proven reliable
    "Fokon"   => 650   # Apex — years of clean Sols
  }.freeze

  def credit_tier
    score = credit_score || 0
    case score
    when 0...100   then "Nouvo"
    when 100...300 then "Pijon"
    when 300...500 then "Toutrèl"
    when 500...650 then "Malfini"
    else                "Fokon"
    end
  end

  def tier_icon
    case credit_tier
    when "Nouvo"    then "🥚"
    when "Pijon"    then "🐦"
    when "Toutrèl"  then "🕊️"
    when "Malfini"  then "🦅"
    when "Fokon"    then "⚡"
    end
  end

  # Loan limits in USD, converted to HTG at live rate
  LOAN_LIMITS_USD = {
    "Nouvo"   => 0,
    "Pijon"   => 0,
    "Toutrèl" => 500,
    "Malfini" => 1_500,
    "Fokon"   => 2_500
  }.freeze

  def loan_limit
    base_usd = LOAN_LIMITS_USD[credit_tier] || 0
    base_usd *= 2 if bonid_verified?
    (base_usd * RateService.usd_htg_rate).round(2)
  end

  def loan_limit_usd
    base = LOAN_LIMITS_USD[credit_tier] || 0
    bonid_verified? ? base * 2 : base
  end

  def points_to_next_tier
    return 0 if credit_tier == "Fokon"

    target = case credit_tier
             when "Nouvo"   then 100
             when "Pijon"   then 300
             when "Toutrèl" then 500
             when "Malfini" then 650
             end
    target - (credit_score || 0)
  end

  # ── Launch Region Gating ──
  ALLOWED_COMMUNES = [
    "Côtes-de-Fer", "Cotes-de-Fer", "Kòt-de-Fè", "Kot de Fe",
    "côtes-de-fer", "cotes-de-fer", "cotes de fer", "Côtes de Fer"
  ].freeze

  def self.commune_allowed?(commune)
    return false if commune.blank? # No address = blocked (must update BonID profile)
    # Normalize: strip, downcase, replace hyphens/spaces for flexible matching
    normalized = commune.strip.downcase.gsub(/[-\s]+/, " ")
    ALLOWED_COMMUNES.any? { |c| normalized == c.downcase.gsub(/[-\s]+/, " ") }
  end

  # ── BonID Identity Verification ──
  def self.from_omniauth(auth)
    info = auth.info
    bonid_id = info["bonid"] || auth.uid

    # ── Address fields from BonID ──
    address_attrs = {
      bonid_street:     info["street"],
      bonid_locality:   info["locality"],
      bonid_commune:    info["commune"],
      bonid_department: info["department"],
      bonid_country:    info["country"]
    }.compact

    # ── Health fields from BonID ──
    health_attrs = {
      bonid_blood_type: info["blood_type"]
    }.compact

    # Find by BonID, provider+uid, or email
    user = find_by(bonid: bonid_id) ||
           find_by(provider: auth.provider, uid: auth.uid) ||
           find_by(email: info["email"])

    if user
      # Link BonID + update verification fields
      unless user.bonid_verified?
        user.update!(
          provider: auth.provider,
          uid: auth.uid,
          bonid: bonid_id,
          bonid_verified_at: Time.current,
          bonid_first_name: info["first_name"],
          bonid_last_name: info["last_name"],
          bonid_photo_url: normalize_bonid_photo_url(info["image"]),
          **address_attrs,
          **health_attrs
        )
      end
      user
    else
      # ── Check commune for new signups ──
      unless commune_allowed?(info["commune"])
        raise RegionRestricted, info["commune"]
      end

      # Create new user — will need cashtag setup after
      create!(
        provider: auth.provider,
        uid: auth.uid,
        email: info["email"] || "#{bonid_id.parameterize}@bonid.ht",
        password: Devise.friendly_token(24),
        cashtag: generate_temp_cashtag,
        bonid: bonid_id,
        bonid_verified_at: Time.current,
        bonid_first_name: info["first_name"],
        bonid_last_name: info["last_name"],
        bonid_photo_url: normalize_bonid_photo_url(info["image"]),
        **address_attrs,
        **health_attrs
      )
    end
  end

  # Custom error for region restriction
  class RegionRestricted < StandardError
    attr_reader :commune
    def initialize(commune)
      @commune = commune
      super("Zèllus disponib nan Côtes-de-Fer sèlman pou kounye a. Ou enskri nan: #{commune}")
    end
  end

  # Custom error for criminal record restriction
  class CriminalRecordRestricted < StandardError
    attr_reader :bonid
    def initialize(bonid)
      @bonid = bonid
      super("BonID #{bonid} gen dosye kriminèl")
    end
  end

  def self.normalize_bonid_photo_url(url)
    return nil if url.blank?
    # Fix ngrok URLs: ensure https and strip erroneous port
    url.sub("http://", "https://").sub(/:3000(?=\/)/, "")
  end

  def self.generate_temp_cashtag
    loop do
      tag = "user#{SecureRandom.alphanumeric(8).downcase}"
      break tag unless exists?(cashtag: tag)
    end
  end

  def bonid_verified?
    bonid.present? && bonid_verified_at.present?
  end

  def bonid_full_name
    [bonid_first_name, bonid_last_name].compact.join(" ").presence
  end

  # ── Cashtag Identity ──
  def display_name
    "$#{cashtag}"
  end

  def cashtag_change_allowed?
    cashtag_changed_at.blank? || cashtag_changed_at < 1.month.ago
  end

  # Award inviter +5 PrioNet points on invitee's first received transfer
  def award_invite_points!
    return unless invited_by.present?
    invited_by.increment!(:credit_score, INVITE_POINTS)
  end

  private

  def normalize_cashtag
    self.cashtag = cashtag.to_s.strip.downcase.delete_prefix("$") if cashtag.present?
  end

  def redeem_invite_code!
    invite_code&.redeem! if invite_code.present?
  end

  def from_oauth?
    provider.present? && uid.present?
  end

  def resolve_invite_code
    return if raw_invite_code.blank?
    code = InviteCode.find_by("UPPER(code) = ?", raw_invite_code.strip.upcase)
    self.invite_code = code
  end

  def validate_invite_code
    if raw_invite_code.blank?
      errors.add(:raw_invite_code, "Kòd envitasyon obligatwa pou enskri")
      return
    end

    code = InviteCode.find_by("UPPER(code) = ?", raw_invite_code.strip.upcase)

    if code.nil?
      errors.add(:raw_invite_code, "Kòd envitasyon sa a pa valid")
    elsif !code.available?
      if code.expired?
        errors.add(:raw_invite_code, "Kòd envitasyon sa a ekspire")
      elsif code.maxed_out?
        errors.add(:raw_invite_code, "Kòd envitasyon sa a deja itilize twòp fwa")
      else
        errors.add(:raw_invite_code, "Kòd envitasyon sa a pa disponib ankò")
      end
    end
  end
end

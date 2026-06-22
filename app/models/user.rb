class User < ApplicationRecord
  # OTP-only auth: keep :database_authenticatable for session/sign_in plumbing
  # (encrypted_password column stays defaulted to "" and is unused). Dropped
  # :recoverable (no password to reset) and :validatable (would force password
  # presence/length on every save — we validate email manually below).
  devise :database_authenticatable, :registerable,
         :rememberable,
         :omniauthable, omniauth_providers: [ :bonid ]

  EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: EMAIL_FORMAT, message: "fòma imèl la pa valid" }

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
  has_many :oauth_tokens, dependent: :destroy
  has_many :sol_circles_created, class_name: "SolCircle", dependent: :nullify
  has_many :agent_transactions_as_customer, class_name: "AgentTransaction", foreign_key: :customer_id
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
  before_validation :normalize_phone_number
  before_validation :resolve_invite_code, on: :create
  after_create :redeem_invite_code!

  validates :cashtag, presence: true,
            uniqueness: { case_sensitive: false },
            format: { with: CASHTAG_FORMAT, message: "dwe 5-20 karaktè alfanimerik" }

  # ── BonID uniqueness (one identity per account) ──
  validates :bonid, uniqueness: { message: "sa a deja lye ak yon lòt kont Zèllus" }, allow_nil: true

  validates :phone_number,
            format: { with: /\A509\d{8}\z/, message: "dwe fòma MonCash (509 + 8 chif)" },
            allow_blank: true,
            uniqueness: { allow_blank: true }

  validates :payout_preference, inclusion: { in: %w[auto htg usd] }

  # ── Transfer PIN (4-digit, BCrypt-hashed) ──
  # Wrong-PIN attempts are tracked in the DB (failed_pin_attempts) so the
  # throttle survives logout/session clears. Hitting the ceiling sets a
  # time-based lock (pin_locked_until); the OTP reset flow is the escape hatch.
  MAX_PIN_ATTEMPTS     = 5
  PIN_LOCKOUT_DURATION = 15.minutes

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

  # True while a lockout window is still in effect.
  def pin_locked?
    pin_locked_until.present? && pin_locked_until.future?
  end

  def pin_lock_remaining_seconds
    return 0 unless pin_locked?

    (pin_locked_until - Time.current).ceil
  end

  def pin_attempts_remaining
    [MAX_PIN_ATTEMPTS - failed_pin_attempts.to_i, 0].max
  end

  # Records one wrong PIN. On hitting the ceiling, starts a lockout window and
  # zeroes the counter. Returns true if this attempt triggered the lock.
  # Uses update_columns to skip the full User validation/callback chain.
  def register_failed_pin_attempt!
    attempts = failed_pin_attempts.to_i + 1
    if attempts >= MAX_PIN_ATTEMPTS
      update_columns(failed_pin_attempts: 0, pin_locked_until: Time.current + PIN_LOCKOUT_DURATION)
      true
    else
      update_columns(failed_pin_attempts: attempts)
      false
    end
  end

  # Clears the counter and any active lock (correct PIN, PIN reset, admin clear).
  def reset_pin_attempts!
    update_columns(failed_pin_attempts: 0, pin_locked_until: nil)
  end

  # ── Wallet ──
  def wallet_balance
    wallet&.htg_balance || 0
  end

  def usd_wallet_balance
    wallet&.usd_balance || 0
  end

  def ensure_wallet!
    w = wallet || create_wallet!
    generate_deposit_address! if deposit_address.blank?
    create_circle_wallet!     if CryptoProvider.circle? && circle_wallet_id.blank?
    w
  end

  def generate_deposit_address!
    addr = CryptoKeyHelper.derive_user_address(id)
    update_column(:deposit_address, addr) if addr.present?
  rescue => e
    Rails.logger.error "User#generate_deposit_address! failed for user=#{id}: #{e.message}"
  end

  # Provisions a Circle Developer-Controlled wallet for this user.
  # Safe to call multiple times — no-ops if wallet already exists.
  def create_circle_wallet!
    return if circle_wallet_id.present?

    result = CircleService.create_wallet(
      user_id:         id,
      idempotency_key: "wallet-#{id}"
    )

    update_columns(
      circle_wallet_id:      result[:wallet_id],
      circle_wallet_address: result[:address]
    )

    Rails.logger.info "User#create_circle_wallet! user=#{id} wallet=#{result[:wallet_id]} address=#{result[:address]}"
  rescue => e
    Rails.logger.error "User#create_circle_wallet! failed for user=#{id}: #{e.message}"
    # Non-fatal: user can still operate with self-hosted fallback
  end

  # ── Daily Transfer Limit (~500 USD) ──
  DAILY_TRANSFER_LIMIT_HTG = 67_750

  def transfers_today_total
    transfers.where("created_at >= ?", Time.current.beginning_of_day)
             .where.not(status: %w[failed expired])
             .sum(:amount)
  end

  def daily_transfer_limit
    daily_transfer_limit_override.presence || DAILY_TRANSFER_LIMIT_HTG
  end

  def daily_transfer_remaining
    [ daily_transfer_limit - transfers_today_total, 0 ].max
  end

  # Payout preference: auto = use first available, htg = MonCash, usd = Base wallet
  def prefers_usd_payout?
    payout_preference == "usd" || (payout_preference == "auto" && payment_methods.active.crypto_wallet.exists?)
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
    "Folkon"   => 650   # Apex — years of clean Sols
  }.freeze

  def credit_tier
    score = credit_score || 0
    case score
    when 0...100   then "Nouvo"
    when 100...300 then "Pijon"
    when 300...500 then "Toutrèl"
    when 500...650 then "Malfini"
    else                "Folkon"
    end
  end

  def tier_icon
    case credit_tier
    when "Nouvo"    then "🥚"
    when "Pijon"    then "🐦"
    when "Toutrèl"  then "🕊️"
    when "Malfini"  then "🦅"
    when "Folkon"    then "⚡"
    end
  end

  # Loan limits in USD, converted to HTG at live rate
  LOAN_LIMITS_USD = {
    "Nouvo"   => 0,
    "Pijon"   => 0,
    "Toutrèl" => 500,
    "Malfini" => 1_500,
    "Folkon"   => 2_500
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
    return 0 if credit_tier == "Folkon"

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

    # Validate against BonID API to get the canonical BonID.
    # OAuth uid may differ from the actual BonID (e.g. internal ID vs citizen ID).
    begin
      api_result = BonIdService.lookup(bonid_id)
      if api_result[:success] && api_result[:bonid].present?
        bonid_id = api_result[:bonid]
      end
    rescue => e
      Rails.logger.warn "BonID API lookup during OAuth failed for #{bonid_id}: #{e.message} — using OAuth value"
    end

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

    # Find by BonID (canonical), provider+uid (may be old format), or email
    raw_uid = info["bonid"] || auth.uid
    user = find_by(bonid: bonid_id) ||
           find_by(provider: auth.provider, uid: auth.uid) ||
           (raw_uid != bonid_id ? find_by(bonid: raw_uid) : nil) ||
           find_by(email: info["email"])

    if user
      # User just completed OAuth consent on BonID — trust the callback data.
      # The consent prompt is forced (prompt: "consent" in devise.rb),
      # so reaching here means the user explicitly approved.
      # Revocation is handled separately via webhooks + periodic rechecks.
      unless user.bonid_verified?
        user.update!(
          provider: auth.provider,
          uid: auth.uid,
          bonid: bonid_id,
          bonid_verified_at: Time.current,
          bonid_first_name: info["first_name"],
          bonid_last_name: info["last_name"],
          bonid_photo_url: normalize_bonid_photo_url(info["image"]),
          bonid_rechecked_at: Time.current,
          **address_attrs,
          **health_attrs
        )
        Rails.logger.info "BonID verified for user #{user.id} via OAuth consent (bonid: #{bonid_id})"
      else
        # Already verified — just refresh data from BonID
        user.update!(
          bonid_first_name: info["first_name"],
          bonid_last_name: info["last_name"],
          bonid_photo_url: normalize_bonid_photo_url(info["image"]),
          bonid_rechecked_at: Time.current,
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

      # Create new user — OAuth consent was just approved, so mark as verified
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
        bonid_rechecked_at: Time.current,
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
    [ bonid_first_name, bonid_last_name ].compact.join(" ").presence
  end

  # ── UMA (Universal Money Address) ──
  def uma_address
    "#{cashtag}@#{LightsparkConfig::UMA_DOMAIN}"
  end

  def uma_enabled?
    uma_enabled && cashtag.present?
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

  # Transfer PIN — the /login/pin gate uses this to decide between "create
  # PIN" and "enter PIN" mode.
  def has_transfer_pin?
    transfer_pin_digest.present?
  end

  private

  def normalize_cashtag
    self.cashtag = cashtag.to_s.strip.downcase.delete_prefix("$") if cashtag.present?
  end

  # Accepts the phone in any shape — "509XXXXXXXX", "+509 XX XX XX XX",
  # or the 8-digit local part — and stores it as the canonical "509XXXXXXXX".
  def normalize_phone_number
    return if phone_number.blank?

    digits = phone_number.gsub(/\D/, "")
    digits = digits[3..] if digits.length == 11 && digits.start_with?("509")
    self.phone_number = digits.present? ? "509#{digits}" : nil
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

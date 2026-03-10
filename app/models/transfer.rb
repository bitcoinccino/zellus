class Transfer < ApplicationRecord
  def to_param
    token
  end

  belongs_to :user
  belongs_to :business, optional: true
  has_many :business_line_items, dependent: :destroy

  # String-backed enums
  enum :status, {
    pending:            "pending",
    awaiting_consent:   "awaiting_consent",
    funded:             "funded",
    sent:               "sent",
    claimed:            "claimed",
    completed:          "completed",
    expired:            "expired",
    refunded:           "refunded",
    failed:             "failed"
  }

  has_one :bonid_consent_request, dependent: :destroy

  enum :asset, { htg: "htg", usdc: "usdc", eth: "eth", wbtc: "wbtc", tslax: "tslax", nvdax: "nvdax", aaplx: "aaplx", coinx: "coinx", googlx: "googlx" }

  # ── Platform fee (centralized in FeeService) ──

  # ── Callbacks ──
  before_validation :ensure_token
  before_create     :calculate_fee

  # ── Validations ──
  validates :token,  presence: true, uniqueness: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :asset,  presence: true
  validates :status, presence: true

  validates :receiver_name, length: { maximum: 100 }, allow_blank: true
  validates :note, length: { maximum: 280 }, allow_blank: true

  validates :receiver_phone,
            format: { with: /\A509\d{8}\z/, message: "dwe yon nimewo MonCash valid (509 + 8 chif)" },
            allow_blank: true

  validates :receiver_email,
            format: { with: URI::MailTo::EMAIL_REGEXP, message: "dwe yon imèl valid" },
            allow_blank: true

  validates :receiver_wallet_address,
            format: { with: /\A0x[a-fA-F0-9]{40}\z/, message: "dwe yon adrès Base valid" },
            allow_blank: true

  validates :receiver_cashtag,
            format: { with: /\A[a-zA-Z0-9]{5,20}\z/, message: "dwe yon Zellustag valid" },
            allow_blank: true

  validate :receiver_destination_present

  # ── Scopes ──
  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where(status: %w[pending funded sent claimed]) }

  # ── Limits (HTG amounts) ──
  SEND_MIN_HTG = 50
  SEND_MAX_HTG = 50_000

  # ── Helpers ──

  def htg_transfer?
    htg?
  end

  def crypto_transfer?
    usdc? || eth? || wbtc? || tslax? || nvdax? || aaplx? || coinx? || googlx?
  end

  def stock_transfer?
    tslax? || nvdax? || aaplx? || coinx? || googlx?
  end

  def bank_transfer?
    htg? && receiver_bank_account.present?
  end

  def asset_label
    asset.to_s.upcase
  end

  def wallet_funded?
    funding_source == "wallet"
  end

  def wallet_payout?
    payout_method == "wallet"
  end

  def receiver_display
    if receiver_cashtag.present?
      "$#{receiver_cashtag}"
    elsif receiver_bank_account.present?
      "#{receiver_bank_name || 'UNIBANK'} ••••#{receiver_bank_account.last(4)}"
    elsif receiver_phone.present?
      receiver_phone
    elsif receiver_wallet_address.present?
      "#{receiver_wallet_address.first(6)}...#{receiver_wallet_address.last(4)}"
    elsif receiver_email.present?
      receiver_email
    else
      "—"
    end
  end

  def usdc_wallet_transfer?
    usdc? && receiver_cashtag.present? && receiver_wallet_address.blank?
  end

  def usdc_address_transfer?
    usdc? && receiver_wallet_address.present? && receiver_cashtag.blank?
  end

  def stock_wallet_transfer?
    stock_transfer? && receiver_cashtag.present?
  end

  def awaiting_claim?
    funded? && htg? && receiver_phone.blank?
  end

  def can_claim?
    funded? && !expired_now?
  end

  def expired_now?
    expires_at.present? && expires_at < Time.current
  end

  def mark_expired_if_needed!
    return false unless funded? && expired_now?

    update!(status: :expired)
    true
  end

  private

  def ensure_token
    self.token ||= loop do
      candidate = SecureRandom.urlsafe_base64(12)
      break candidate unless self.class.exists?(token: candidate)
    end
  end

  def calculate_fee
    rate = FeeService.transfer_fee_rate(self)
    self.fee        = (amount * rate).round(2)
    self.net_amount = (amount - fee).round(2)
  end

  def receiver_destination_present
    if htg?
      if receiver_phone.blank? && receiver_email.blank? && receiver_cashtag.blank? && receiver_bank_account.blank?
        errors.add(:base, "Ou dwe bay yon $zellustag, nimewo MonCash, kont bank, oswa yon imèl.")
      end
    else
      # Crypto: allow either wallet address OR $zellustag for wallet-to-wallet
      if receiver_wallet_address.blank? && receiver_cashtag.blank?
        errors.add(:base, "Ou dwe bay yon adrès Base oswa yon $zellustag.")
      end
    end
  end
end

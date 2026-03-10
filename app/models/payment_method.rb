class PaymentMethod < ApplicationRecord
  belongs_to :user

  enum :category, { mobile_wallet: "mobile_wallet", crypto_wallet: "crypto_wallet", bank_account: "bank_account" }
  enum :provider, { moncash: "moncash", base: "base", unibank: "unibank" }
  enum :network, { base_network: "base" }, prefix: :network
  enum :asset, { usdc: "usdc", eth: "eth" }, prefix: :asset

  scope :active, -> { where(active: true) }

  before_validation :ensure_token
  before_validation :apply_defaults
  before_validation :normalize_account_number, if: :mobile_wallet?
  before_validation :normalize_wallet_address, if: :crypto_wallet?
  before_validation :normalize_bank_account, if: :bank_account?

  validates :token, presence: true, uniqueness: true
  validates :category, presence: true
  validates :provider, presence: true
  validates :label, length: { maximum: 50 }, allow_blank: true

  validates :account_number, presence: true,
            format: { with: /\A509\d{8}\z/, message: "must be a valid MonCash number (509 + 8 digits)" },
            if: :mobile_wallet?
  validates :account_number, uniqueness: { scope: [:user_id, :provider, :category], message: "is already saved" }, if: :mobile_wallet?

  validates :wallet_address, presence: true,
            format: { with: /\A0x[a-fA-F0-9]{40}\z/, message: "must be a valid EVM wallet address" }, if: :crypto_wallet?
  validates :wallet_address, uniqueness: { scope: [:user_id, :provider, :category], message: "is already saved" }, if: :crypto_wallet?
  validates :network, presence: true, if: :crypto_wallet?

  validates :bank_account_number, presence: true, if: :bank_account?
  validates :bank_account_number, uniqueness: { scope: [:user_id, :provider, :category], message: "deja anrejistre" }, if: :bank_account?
  validates :bank_name, presence: true, if: :bank_account?

  def display_label
    label.presence || default_label
  end

  def masked_account_number
    return account_number if account_number.blank? || account_number.length < 4

    "(509) •••• #{account_number.last(4)}"
  end

  def masked_wallet_address
    return wallet_address if wallet_address.blank? || wallet_address.length < 10

    "#{wallet_address.first(6)}...#{wallet_address.last(4)}"
  end

  def primary_value
    if mobile_wallet?
      account_number
    elsif bank_account?
      bank_account_number
    else
      wallet_address
    end
  end

  def masked_bank_account
    return bank_account_number if bank_account_number.blank? || bank_account_number.length < 4
    "••••#{bank_account_number.last(4)}"
  end

  def to_param
    token
  end

  private

  def apply_defaults
    self.category ||= "mobile_wallet"

    if mobile_wallet?
      self.provider ||= "moncash"
      self.network = nil
      self.asset = nil if asset.blank?
    elsif crypto_wallet?
      self.provider ||= "base"
      self.network ||= "base"
      self.asset ||= "usdc"
      self.account_number = nil if account_number.blank?
    elsif bank_account?
      self.provider ||= "unibank"
      self.network = nil
      self.asset = nil
      self.bank_name ||= "UNIBANK"
    end
  end

  def default_label
    return "MonCash" if mobile_wallet?
    return bank_name.presence || "UNIBANK" if bank_account?

    parts = ["Base"]
    parts << asset.to_s.upcase if asset.present?
    parts.join(" ")
  end

  def normalize_account_number
    digits = account_number.to_s.gsub(/\D/, "")
    digits = "509#{digits}" if digits.length == 8
    self.account_number = digits
  end

  def normalize_wallet_address
    self.wallet_address = wallet_address.to_s.strip
  end

  def normalize_bank_account
    self.bank_account_number = bank_account_number.to_s.strip
  end

  def ensure_token
    self.token ||= loop do
      candidate = SecureRandom.urlsafe_base64(12)
      break candidate unless self.class.exists?(token: candidate)
    end
  end

end

class PaymentMethod < ApplicationRecord
  belongs_to :user

  enum :category, { mobile_wallet: "mobile_wallet", crypto_wallet: "crypto_wallet" }
  enum :provider, { moncash: "moncash", base: "base" }
  enum :network, { base_network: "base" }, prefix: :network
  enum :asset, { usdc: "usdc", eth: "eth" }, prefix: :asset

  scope :active, -> { where(active: true) }

  before_validation :apply_defaults
  before_validation :normalize_account_number, if: :mobile_wallet?
  before_validation :normalize_wallet_address, if: :crypto_wallet?

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

  def display_label
    label.presence || default_label
  end

  def masked_account_number
    return account_number if account_number.blank? || account_number.length < 4

    "#{account_number.first(5)}***#{account_number.last(3)}"
  end

  def masked_wallet_address
    return wallet_address if wallet_address.blank? || wallet_address.length < 10

    "#{wallet_address.first(6)}...#{wallet_address.last(4)}"
  end

  def primary_value
    mobile_wallet? ? account_number : wallet_address
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
    end
  end

  def default_label
    return "MonCash" if mobile_wallet?

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
end

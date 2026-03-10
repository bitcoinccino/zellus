class WalletLedgerEntry < ApplicationRecord
  belongs_to :wallet
  belongs_to :user, optional: true
  belongs_to :reference, polymorphic: true, optional: true

  before_create :generate_token

  ENTRY_TYPES = %w[deposit withdrawal transfer_out transfer_in fee instant_fee refund conversion_out conversion_in conversion_fee].freeze
  ASSETS      = %w[htg usdc eth wbtc tslax nvdax aaplx coinx googlx].freeze

  validates :entry_type,    presence: true, inclusion: { in: ENTRY_TYPES }
  validates :asset,         presence: true, inclusion: { in: ASSETS }
  validates :amount,        presence: true, numericality: { greater_than: 0 }
  validates :balance_after, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :moncash_transaction_id, uniqueness: true, allow_nil: true

  scope :deposits,      -> { where(entry_type: "deposit") }
  scope :withdrawals,   -> { where(entry_type: "withdrawal") }
  scope :transfers_out, -> { where(entry_type: "transfer_out") }
  scope :transfers_in,  -> { where(entry_type: "transfer_in") }
  scope :fees,          -> { where(entry_type: "fee") }
  scope :instant_fees,  -> { where(entry_type: "instant_fee") }
  scope :refunds,         -> { where(entry_type: "refund") }
  scope :conversions_out, -> { where(entry_type: "conversion_out") }
  scope :conversions_in,  -> { where(entry_type: "conversion_in") }
  scope :recent_first,  -> { order(created_at: :desc) }

  # ── Asset scopes ──
  scope :htg_entries,  -> { where(asset: "htg") }
  scope :usdc_entries, -> { where(asset: "usdc") }

  def credit?
    %w[deposit transfer_in refund conversion_in].include?(entry_type)
  end

  def debit?
    %w[withdrawal transfer_out fee instant_fee conversion_out conversion_fee].include?(entry_type)
  end

  def asset_label
    asset.to_s == "usdc" ? "USD" : asset.to_s.upcase
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(12)
  end
end

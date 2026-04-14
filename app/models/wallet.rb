class Wallet < ApplicationRecord
  belongs_to :user
  has_many :wallet_ledger_entries, dependent: :restrict_with_error

  enum :status, { open: 0, held: 1, closed: 2 }

  ASSETS = %w[htg usd eth wbtc].freeze

  # DB column is usdc_balance; alias to usd_balance for codebase consistency
  alias_attribute :usd_balance, :usdc_balance

  validates :htg_balance,  numericality: { greater_than_or_equal_to: 0 }
  validates :usd_balance, numericality: { greater_than_or_equal_to: 0 }
  validates :eth_balance,  numericality: { greater_than_or_equal_to: 0 }
  validates :wbtc_balance, numericality: { greater_than_or_equal_to: 0 }

  # ── Multi-asset helpers (mirrors SolEscrowAccount) ──
  def balance_for(asset)
    case asset.to_s
    when "htg"  then htg_balance
    when "usd" then usd_balance
    when "eth"  then eth_balance
    when "wbtc" then wbtc_balance
    else BigDecimal("0")
    end
  end

  # Backward-compatible: sufficient_balance?(500) → HTG
  # Multi-asset:         sufficient_balance?("usdc", 10.5)
  def sufficient_balance?(asset_or_amount = nil, amount = nil)
    if amount.nil?
      htg_balance >= asset_or_amount.to_d
    else
      balance_for(asset_or_amount) >= amount.to_d
    end
  end
end

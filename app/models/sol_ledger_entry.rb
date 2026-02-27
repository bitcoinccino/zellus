class SolLedgerEntry < ApplicationRecord
  belongs_to :sol_escrow_account
  belongs_to :sol_round, optional: true
  belongs_to :user, optional: true
  belongs_to :reference, polymorphic: true, optional: true

  ENTRY_TYPES = %w[deposit payout platform_fee creator_fee refund].freeze
  ASSETS = %w[htg usdc].freeze

  validates :entry_type, presence: true, inclusion: { in: ENTRY_TYPES }
  validates :asset, presence: true, inclusion: { in: ASSETS }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :balance_after, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :deposits, -> { where(entry_type: "deposit") }
  scope :payouts, -> { where(entry_type: "payout") }
  scope :fees, -> { where(entry_type: %w[platform_fee creator_fee]) }
  scope :for_round, ->(round) { where(sol_round: round) }
end

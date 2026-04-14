class SolEscrowAccount < ApplicationRecord
  belongs_to :sol_circle
  has_many :sol_ledger_entries, dependent: :restrict_with_error

  enum :status, { open: 0, held: 1, closed: 2 }

  validates :htg_balance, numericality: { greater_than_or_equal_to: 0 }
  validates :usd_balance, numericality: { greater_than_or_equal_to: 0 }

  def balance_for(asset)
    asset == "htg" ? htg_balance : usd_balance
  end

  def sufficient_balance?(asset, amount)
    balance_for(asset) >= amount
  end
end

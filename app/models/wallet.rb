class Wallet < ApplicationRecord
  belongs_to :user
  has_many :wallet_ledger_entries, dependent: :restrict_with_error

  enum :status, { open: 0, held: 1, closed: 2 }

  validates :htg_balance, numericality: { greater_than_or_equal_to: 0 }

  def sufficient_balance?(amount)
    htg_balance >= amount.to_d
  end
end

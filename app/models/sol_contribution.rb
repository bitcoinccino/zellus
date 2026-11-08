class SolContribution < ApplicationRecord
  belongs_to :user
  belongs_to :sol_round

  # This tells Rails that bank_transaction_id refers to a record in the 'transactions' table
  belongs_to :bank_transaction, class_name: "Transaction", optional: true

  # Maps the integer in the DB to readable statuses
  enum :status, { pending: 0, paid: 1, failed: 2 }

  validates :status, presence: true
end

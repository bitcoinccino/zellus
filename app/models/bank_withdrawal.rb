class BankWithdrawal < ApplicationRecord
  belongs_to :user
  belongs_to :wallet
  belongs_to :wallet_ledger_entry, optional: true

  MIN_AMOUNT = 500      # HTG
  MAX_AMOUNT = 250_000  # HTG

  enum :status, {
    pending:    "pending",
    processing: "processing",
    completed:  "completed",
    failed:     "failed"
  }

  before_create :generate_token

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :bank_account_number, presence: true
  validates :bank_name, presence: true

  scope :pending,      -> { where(status: "pending") }
  scope :processing,   -> { where(status: "processing") }
  scope :active,       -> { where(status: %w[pending processing]) }
  scope :recent_first, -> { order(created_at: :desc) }

  def display_status
    case status
    when "pending"    then "An Atant"
    when "processing" then "Ap Trete"
    when "completed"  then "Fini"
    when "failed"     then "Echwe"
    end
  end

  def masked_account
    return bank_account_number if bank_account_number.blank? || bank_account_number.length < 4
    "••••#{bank_account_number.last(4)}"
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(12)
  end
end

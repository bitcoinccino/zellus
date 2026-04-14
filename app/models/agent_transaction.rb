class AgentTransaction < ApplicationRecord
  belongs_to :business
  belongs_to :customer, class_name: "User"
  belongs_to :wallet_ledger_entry, optional: true

  # ── Enums (string-backed for readability) ──
  enum :status, {
    pending: "pending",
    completed: "completed",
    failed: "failed",
    disputed: "disputed"
  }

  enum :transaction_type, {
    cash_in: "cash_in",
    cash_out: "cash_out",
    float_top_up: "float_top_up",
    float_withdraw: "float_withdraw"
  }

  # ── Limits ──
  CASH_IN_MIN = 100      # HTG
  CASH_IN_MAX = 50_000   # HTG

  # ── Validations ──
  validates :amount, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :transaction_type, presence: true
  validates :status, presence: true
  validates :commission_rate, numericality: { greater_than_or_equal_to: 0 }
  validates :commission_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :confirmation_code, presence: true, uniqueness: true
  validates :idempotency_key, uniqueness: true, allow_nil: true

  validates :amount,
    numericality: {
      greater_than_or_equal_to: CASH_IN_MIN,
      less_than_or_equal_to: CASH_IN_MAX,
      message: "dwe ant #{CASH_IN_MIN} ak #{CASH_IN_MAX} HTG"
    },
    if: :cash_in?

  # ── Callbacks ──
  before_validation :generate_confirmation_code, on: :create
  before_validation :calculate_commission, on: :create

  # ── Scopes ──
  scope :recent_first, -> { order(created_at: :desc) }
  scope :today, -> { where("created_at >= ?", Time.current.beginning_of_day) }

  private

  def generate_confirmation_code
    return if confirmation_code.present?

    loop do
      self.confirmation_code = SecureRandom.alphanumeric(6).upcase
      break unless AgentTransaction.exists?(confirmation_code: confirmation_code)
    end
  end

  def calculate_commission
    return if commission_amount.present? && commission_amount > 0

    # Float operations are internal moves — zero commission
    if float_top_up? || float_withdraw?
      self.commission_rate = 0
      self.commission_amount = 0
      return
    end

    rate = commission_rate || business&.agent_commission_rate || 0.02
    self.commission_rate = rate
    self.commission_amount = (amount.to_d * rate).round(2)
  end
end

class Transaction < ApplicationRecord
  belongs_to :user
  enum :status,           { pending: 0, paid: 1, crypto_sent: 2, completed: 3, failed: 4, payout_failed: 5 }
  enum :transaction_type, { buy: "buy", sell: "sell", loan_request: "loan_request", admin_credit_external: "admin_credit_external" }
  enum :crypto_currency,  { usd: "usd", eth: "eth", wbtc: "wbtc", tslax: "tslax", nvdax: "nvdax", aaplx: "aaplx", coinx: "coinx", googlx: "googlx" }

  # ── Token (public-facing ID) ──
  before_validation :ensure_token, on: :create

  # ── Live Dashboard Broadcast ──
  after_update_commit :broadcast_to_admin_dashboard, if: -> { saved_change_to_status? && completed? }

  def to_param
    token
  end

  # ── Loan Constants ──
  LOAN_PURPOSES = {
    "elaji_biznis"         => "Elaji Biznis",
    "achte_envante"        => "Achte Envantè",
    "ekipman_ijans"        => "Ekipman Ijans",
    "pwovizyon_agrikol"    => "Pwovizyon Agrikòl",
    "edikasyon"            => "Edikasyon",
    "sipo_ti_biznis"       => "Sipò pou Ti Biznis",
    "eneji_renouvlab"      => "Enèji Renouvlab",
    "sevis_konsiltasyon"   => "Sèvis Konsiltasyon",
    "fomasyon_pwofesyonel" => "Fòmasyon Pwofesyonèl",
    "devlopman_kominote"   => "Devlopman Kominotè",
    "konstriksyon"         => "Konstriksyon",
    "sevis_pesonel"        => "Sèvis Pèsonèl",
    "teknoloji"            => "Teknoloji",
    "swen_medikal"         => "Swen Medikal (Lopital)",
    "lot"                  => "Lòt"
  }.freeze

  REPAYMENT_TERMS = {
    4  => "1 Mwa (4 semèn)",
    8  => "2 Mwa (8 semèn)",
    12 => "3 Mwa (12 semèn)",
    26 => "6 Mwa (26 semèn)",
    52 => "1 Ane (52 semèn)"
  }.freeze

  LOAN_INTEREST_RATE_PER_WEEK = BigDecimal("0.0075") # 0.75% per week (~3% monthly)

  # ── Loan Validations ──
  validates :loan_purpose, inclusion: { in: LOAN_PURPOSES.keys }, if: :loan_request?
  validates :repayment_term_weeks, presence: true,
            numericality: { greater_than: 0, less_than_or_equal_to: 52 },
            if: :loan_request?
  validates :collateral_description, length: { maximum: 500 }, allow_blank: true

  # ── Loan Callbacks ──
  before_validation :calculate_loan_terms, if: :loan_request?

  # ── Loan Methods ──
  def calculate_loan_terms
    return unless repayment_term_weeks.present? && fiat_amount.present?
    rate = LOAN_INTEREST_RATE_PER_WEEK * repayment_term_weeks
    self.loan_interest_rate = rate
    self.loan_total_repayable = (fiat_amount * (1 + rate)).round(2)
    self.loan_due_date = (created_at || Time.current).to_date + repayment_term_weeks.weeks
  end

  def loan_purpose_label
    LOAN_PURPOSES[loan_purpose] || loan_purpose
  end

  def repayment_term_label
    REPAYMENT_TERMS[repayment_term_weeks] || "#{repayment_term_weeks} semèn"
  end

  def loan_interest_amount
    return 0 unless loan_total_repayable.present? && fiat_amount.present?
    loan_total_repayable - fiat_amount
  end

  def loan_overdue?
    loan_request? && loan_due_date.present? && loan_due_date < Date.current && !completed?
  end

  FRIENDLY_ERRORS = {
    /exceeds balance/i              => "Sistèm nan pa kapab trete tranzaksyon sa a kounye a. Tanpri eseye ankò pita oswa kontakte sipò.",
    /insufficient funds/i           => "Sistèm nan pa kapab trete tranzaksyon sa a kounye a. Tanpri eseye ankò pita oswa kontakte sipò.",
    /nonce too low/i                => "Te gen yon konfli. Tanpri eseye ankò.",
    /replacement transaction/i      => "Yon tranzaksyon idantik te detekte. Tanpri kontakte sipò.",
    /invalid address/i              => "Adrès pòtfèy la pa valid. Tanpri verifye epi eseye ankò.",
    /gas required exceeds allowance/i => "Tranzaksyon an pa kapab trete. Tanpri eseye ankò pita.",
    /execution reverted/i           => "Tranzaksyon an te rejte. Tanpri kontakte sipò.",
    /TREASURY_PRIVATE_KEY not set/i => "Erè konfigirasyon sèvè. Tanpri kontakte sipò.",
    /RPC returned no tx hash/i      => "Tranzaksyon an pa t konfime. Tanpri kontakte sipò.",
    /connection refused|timeout|ECONNREFUSED/i => "Nou pa kapab konekte ak rezo a. Tanpri eseye ankò pita.",
    /partner is blocked/i           => "Sèvis peman an pa disponib. Tanpri kontakte sipò.",
    /MonCash connection failed/i    => "Sèvis MonCash pa disponib kounye a. Tanpri eseye ankò pita.",
    /MonCash customer check failed|MonCash payout failed|No short code for user account/i => "Nou resevwa depo USDC ou, men peman HTG a pa t kapab fèt toujou. Ekip sipò ap regle sa pou ou.",
  }

  def friendly_failure_reason
    return nil unless failure_reason.present?
    match = FRIENDLY_ERRORS.find { |pattern, _| failure_reason.match?(pattern) }
    match ? match[1] : "Yon erè te pase. Tanpri kontakte sipò."
  end

  private

  def ensure_token
    self.token ||= loop do
      candidate = SecureRandom.urlsafe_base64(12)
      break candidate unless self.class.exists?(token: candidate)
    end
  end

  def broadcast_to_admin_dashboard
    ActionCable.server.broadcast("admin_dashboard", {
      type: "transaction_completed",
      transaction_id: id,
      fee_amount: fee_amount.to_f,
      fiat_amount: fiat_amount.to_f,
      transaction_type: transaction_type,
      user_cashtag: user&.cashtag
    })
  rescue => e
    Rails.logger.error "AdminDashboard broadcast error: #{e.message}"
  end
end

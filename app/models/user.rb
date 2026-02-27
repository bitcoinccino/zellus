class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Associations
  has_many :transactions, dependent: :destroy
  has_many :payment_methods, dependent: :destroy
  has_many :payment_requests, dependent: :destroy
  has_many :sol_memberships, dependent: :destroy
  has_many :sol_circles, through: :sol_memberships
  has_many :transfers, dependent: :destroy
  has_one  :wallet, dependent: :destroy
  has_many :sol_circles_created, class_name: "SolCircle", dependent: :nullify

  validates :payout_preference, inclusion: { in: %w[auto htg usdc] }

  # ── Transfer PIN (4-digit, BCrypt-hashed) ──
  def transfer_pin=(raw_pin)
    require "bcrypt"
    if raw_pin.present?
      self.transfer_pin_digest = BCrypt::Password.create(raw_pin)
      self.transfer_pin_set_at = Time.current
    else
      self.transfer_pin_digest = nil
      self.transfer_pin_set_at = nil
    end
  end

  def transfer_pin_set?
    transfer_pin_digest.present?
  end

  def verify_transfer_pin(raw_pin)
    require "bcrypt"
    return false unless transfer_pin_digest.present? && raw_pin.present?

    BCrypt::Password.new(transfer_pin_digest) == raw_pin.to_s
  end

  # ── Wallet ──
  def wallet_balance
    wallet&.htg_balance || 0
  end

  def ensure_wallet!
    wallet || create_wallet!
  end

  # ── Daily Transfer Limit ──
  DAILY_TRANSFER_LIMIT_HTG = 100_000

  def transfers_today_total
    transfers.where("created_at >= ?", Time.current.beginning_of_day)
             .where.not(status: %w[failed expired])
             .sum(:amount)
  end

  def daily_transfer_remaining
    [DAILY_TRANSFER_LIMIT_HTG - transfers_today_total, 0].max
  end

  # Payout preference: auto = use first available, htg = MonCash, usdc = Base wallet
  def prefers_usdc_payout?
    payout_preference == "usdc" || (payout_preference == "auto" && payment_methods.active.crypto_wallet.exists?)
  end

  def prefers_htg_payout?
    payout_preference == "htg" || (payout_preference == "auto" && !payment_methods.active.crypto_wallet.exists?)
  end

  MAX_CREDIT_SCORE = 800

  TIER_THRESHOLDS = {
    "Nouvo"   => 0,    # Unproven — no Sol history
    "Pijon"   => 100,  # Completed a clean 3-month Sol
    "Toutrèl" => 300,  # Consistent track record
    "Malfini" => 500,  # Proven reliable
    "Fokon"   => 650   # Apex — years of clean Sols
  }.freeze

  def credit_tier
    score = credit_score || 0
    case score
    when 0...100   then "Nouvo"
    when 100...300 then "Pijon"
    when 300...500 then "Toutrèl"
    when 500...650 then "Malfini"
    else                "Fokon"
    end
  end

  def tier_icon
    case credit_tier
    when "Nouvo"    then "🥚"
    when "Pijon"    then "🐦"
    when "Toutrèl"  then "🕊️"
    when "Malfini"  then "🦅"
    when "Fokon"    then "⚡"
    end
  end

  def loan_limit
    case credit_tier
    when "Nouvo"    then 0
    when "Pijon"    then 0
    when "Toutrèl"  then 5_000.00
    when "Malfini"  then 25_000.00
    when "Fokon"    then 100_000.00
    end
  end

  def points_to_next_tier
    return 0 if credit_tier == "Fokon"

    target = case credit_tier
             when "Nouvo"   then 100
             when "Pijon"   then 300
             when "Toutrèl" then 500
             when "Malfini" then 650
             end
    target - (credit_score || 0)
  end
end

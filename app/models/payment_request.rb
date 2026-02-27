class PaymentRequest < ApplicationRecord
  belongs_to :user
  belongs_to :payment_method, optional: true
  belongs_to :sol_round, optional: true

  enum :status, { active: "active", paid: "paid", expired: "expired", canceled: "canceled" }
  enum :asset, { htg: "htg", usdc: "usdc" }

  before_validation :ensure_token
  after_update :fulfill_sol_contribution, if: -> { saved_change_to_status? && paid? && sol_round_id.present? }

  validates :token, presence: true, uniqueness: true
  validates :asset, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :note, length: { maximum: 140 }, allow_blank: true
  validates :receiver_account_number,
            format: { with: /\A509\d{8}\z/, message: "must be a valid MonCash number (509 + 8 digits)" },
            allow_blank: true
  validates :receiver_wallet_address,
            format: { with: /\A0x[a-fA-F0-9]{40}\z/, message: "must be a valid EVM wallet address" },
            allow_blank: true

  scope :recent_first, -> { order(created_at: :desc) }

  def expired_now?
    expires_at.present? && expires_at < Time.current
  end

  def time_until_expiry
    return nil if expires_at.blank?

    expires_at - Time.current
  end

  def expires_soon?
    active? && time_until_expiry.present? && time_until_expiry <= 30.minutes
  end

  def expiry_countdown_label
    return "No expiration" if expires_at.blank?
    return "Expired" if expired_now?

    remaining = time_until_expiry.to_i
    hours = remaining / 3600
    minutes = (remaining % 3600) / 60

    if hours > 0
      "#{hours}h #{minutes}m left"
    else
      "#{[minutes, 0].max}m left"
    end
  end

  def mark_expired_if_needed!
    return false unless active? && expired_now?

    update!(status: :expired)
    PaymentRequestMailer.with(payment_request_id: id).request_expired.deliver_later
    true
  end

  def receiver_present?
    receiver_account_number.present? || receiver_wallet_address.present?
  end

  def receiver_mobile_wallet?
    receiver_category == "mobile_wallet" || receiver_account_number.present?
  end

  def receiver_crypto_wallet?
    receiver_category == "crypto_wallet" || receiver_wallet_address.present?
  end

  def receiver_display_label
    receiver_label.presence || (receiver_mobile_wallet? ? "MonCash Receiver" : "Crypto Wallet Receiver")
  end

  def masked_receiver_account_number
    return receiver_account_number if receiver_account_number.blank? || receiver_account_number.length < 4

    receiver_account_number.gsub(/\d(?=\d{4})/, "•")
  end

  def masked_receiver_wallet_address
    return receiver_wallet_address if receiver_wallet_address.blank? || receiver_wallet_address.length < 10

    "#{receiver_wallet_address.first(6)}...#{receiver_wallet_address.last(4)}"
  end

  # Is this a Sol circle payment request?
  def sol_payment?
    sol_round_id.present?
  end

  private

  # When a Sol PaymentRequest is paid, auto-create SolContribution & check round completion
  def fulfill_sol_contribution
    round = sol_round
    circle = round.sol_circle

    # Only create one contribution per user per round (they may pay HTG or USDC — first one wins)
    return if round.sol_contributions.exists?(user_id: user_id)

    SolContribution.create!(
      user_id: user_id,
      sol_round: round,
      status: :paid
    )

    # Record deposit in escrow ledger
    SolEscrowService.new(circle).deposit!(
      user: user,
      round: round,
      asset: asset,
      amount: amount,
      reference: self
    )

    # Cancel the other payment option (if they paid HTG, cancel USDC and vice versa)
    PaymentRequest.where(sol_round: round, user_id: user_id, status: :active)
                  .where.not(id: id)
                  .update_all(status: "canceled")

    # Check if all members have now paid — if so, trigger payout
    orchestrator = SolOrchestrator.new(circle)
    if orchestrator.send(:all_members_paid?, round)
      orchestrator.send(:trigger_payout!, round)
      round.update!(status: :paid_out)
      orchestrator.send(:start_next_round!)
    end
  rescue => e
    Rails.logger.error "PaymentRequest#fulfill_sol_contribution failed: #{e.message}"
  end

  def ensure_token
    self.token ||= loop do
      candidate = SecureRandom.urlsafe_base64(12)
      break candidate unless self.class.exists?(token: candidate)
    end
  end
end

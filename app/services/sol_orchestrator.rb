class SolOrchestrator
  GRACE_PERIOD_HOURS = 48
  LATE_PAYMENT_PENALTY = -25
  DEFAULT_PENALTY = -50

  def initialize(circle)
    @circle = circle
  end

  def process_current_round!
    current_round = @circle.sol_rounds.collecting.first

    if current_round && all_members_paid?(current_round)
      # All paid — trigger payout with fee deductions
      trigger_payout!(current_round)
      current_round.update!(status: :paid_out)
      start_next_round!

    elsif current_round && grace_period_expired?(current_round)
      # Grace period passed — handle delinquent members
      handle_missed_payments(current_round)

    elsif current_round.nil?
      # Brand new circle — kick off round 1
      start_next_round!

    else
      # Still within grace period — send reminders
      send_payment_reminders(current_round)
    end
  end

  # Public method to remove a member who can't pay
  def remove_defaulting_member!(user)
    membership = @circle.sol_memberships.find_by(user: user, active: true)
    return unless membership

    membership.default!(reason: "Pa kapab peye kontribisyon Sol")

    # Email: member defaulted
    SolMailer.with(circle: @circle, user: user).member_defaulted.deliver_later

    if @circle.sol_memberships.active_members.count >= 3
      Rails.logger.info "SolOrchestrator: Manm #{user.id} retire nan Sol #{@circle.id}. Sol kontinye."
    else
      @circle.completed!
      Rails.logger.warn "SolOrchestrator: Sol #{@circle.id} fini bonè — pa ase manm."
    end
  end

  private

  # ── Round Creation ──────────────────────────────────────────────

  def start_next_round!
    next_number = (@circle.sol_rounds.maximum(:round_number) || 0) + 1
    active_members = @circle.sol_memberships.active_members.order(:position)
    return if next_number > active_members.count

    # Find the next active member in rotation
    recipient_membership = active_members.find_by(position: next_number)

    # Skip defaulted positions — find next active member
    unless recipient_membership
      recipient_membership = active_members.where("position > ?", next_number).first
      return unless recipient_membership
    end

    recipient = recipient_membership.user

    new_round = @circle.sol_rounds.create!(
      round_number: next_number,
      payout_user: recipient,
      status: :collecting
    )

    # Generate dual payment requests (HTG + USDC) for everyone EXCEPT the recipient
    htg_amount, usdc_amount = sol_contribution_amounts

    @circle.sol_memberships.active_members.where.not(user_id: recipient.id).each do |membership|
      htg_pr = PaymentRequest.create!(
        user: membership.user,
        sol_round: new_round,
        amount: htg_amount,
        asset: "htg",
        note: "Sol #{@circle.name}: Wonn #{next_number} (MonCash)",
        expires_at: GRACE_PERIOD_HOURS.hours.from_now
      )

      PaymentRequest.create!(
        user: membership.user,
        sol_round: new_round,
        amount: usdc_amount,
        asset: "usdc",
        note: "Sol #{@circle.name}: Wonn #{next_number} (USDC)",
        expires_at: GRACE_PERIOD_HOURS.hours.from_now
      )

      # Email: new round started — pay now
      SolMailer.with(circle: @circle, round: new_round, user: membership.user, payment_request: htg_pr)
               .round_started.deliver_later
    end
  end

  # ── Currency Conversion ─────────────────────────────────────────

  def sol_contribution_amounts
    rate = RateService.sell_rate

    if @circle.htg?
      htg_amount  = @circle.amount
      usdc_amount = (@circle.amount / rate).round(2)
    else
      usdc_amount = @circle.amount
      htg_amount  = (@circle.amount * rate).round(2)
    end

    [htg_amount, usdc_amount]
  end

  # ── Payment Verification ────────────────────────────────────────

  def all_members_paid?(round)
    unpaid_members(round).empty?
  end

  def unpaid_members(round)
    paid_user_ids = round.sol_contributions.pluck(:user_id)
    active_member_ids = @circle.sol_memberships.active_members
                              .where.not(user_id: round.payout_user_id)
                              .pluck(:user_id)
    active_member_ids - paid_user_ids
  end

  def grace_period_expired?(round)
    round.created_at + GRACE_PERIOD_HOURS.hours < Time.current
  end

  # ── Missed Payment Handling ─────────────────────────────────────

  def handle_missed_payments(round)
    missed_user_ids = unpaid_members(round)
    return if missed_user_ids.empty?

    missed_user_ids.each do |user_id|
      membership = @circle.sol_memberships.find_by(user_id: user_id, active: true)
      next unless membership

      CreditScoringService.penalize_late_payment(membership.user, @circle)
    end

    send_final_warnings(round, missed_user_ids)
  end

  # ── Payout with Fee Deductions ──────────────────────────────────

  def trigger_payout!(round)
    # Release funds through escrow — verifies balance, deducts fees, records ledger entries
    escrow = SolEscrowService.new(@circle)
    payout = escrow.release_payout!(round: round)

    net_amount = payout[:net_amount]
    recipient = payout[:recipient]

    # Send actual funds to the recipient via their preferred payment method
    send_payout(recipient, net_amount)

    # Pay the creator their fee (if applicable)
    if payout[:creator_fee] > 0 && @circle.user_id != round.payout_user_id
      send_payout(@circle.user, payout[:creator_fee])
    end

    Rails.logger.info "SolOrchestrator: Peman wonn #{round.round_number} — " \
                      "Resevwa: #{net_amount}, Frè platfòm: #{payout[:platform_fee]}, Frè kreyatè: #{payout[:creator_fee]}"

    # Email: payout received
    SolMailer.with(circle: @circle, round: round, user: recipient, amount: net_amount)
             .payout_received.deliver_later

    CreditScoringService.update_for_round(round)

    if round.round_number >= @circle.total_rounds
      CreditScoringService.reward_completion(@circle)
      @circle.completed!
      escrow.close!

      # Email: circle completed — to all active members
      @circle.sol_memberships.active_members.each do |m|
        SolMailer.with(circle: @circle, user: m.user).circle_completed.deliver_later
      end
    end
  end

  # Send payout to a user via their preferred method (respects user.payout_preference)
  def send_payout(user, htg_amount)
    crypto_wallet = user.payment_methods.active.crypto_wallet.first
    moncash_method = user.payment_methods.active.moncash.first

    if user.prefers_usdc_payout? && crypto_wallet&.wallet_address.present?
      send_usdc_payout(user, htg_amount, crypto_wallet)
    elsif user.prefers_htg_payout? && moncash_method&.account_number.present?
      send_htg_payout(htg_amount, moncash_method)
    elsif crypto_wallet&.wallet_address.present?
      # Fallback: user prefers HTG but has no MonCash — send USDC instead
      send_usdc_payout(user, htg_amount, crypto_wallet)
    elsif moncash_method&.account_number.present?
      # Fallback: user prefers USDC but has no wallet — send HTG instead
      send_htg_payout(htg_amount, moncash_method)
    else
      Rails.logger.error "SolOrchestrator: Itilizatè #{user.id} pa gen okenn metòd peman disponib"
    end
  end

  def send_usdc_payout(user, htg_amount, crypto_wallet)
    rate = RateService.sell_rate
    usdc_amount = (htg_amount / rate).round(6)

    tx = Transaction.create!(
      user: user,
      transaction_type: "buy",
      crypto_currency: "usdc",
      fiat_amount: htg_amount,
      crypto_amount: usdc_amount,
      exchange_rate: rate,
      fee_amount: 0,
      destination_address: crypto_wallet.wallet_address,
      status: :paid
    )

    CryptoTransferWorker.perform_async(tx.id)
    Rails.logger.info "SolOrchestrator: USDC peman #{usdc_amount} -> #{crypto_wallet.masked_wallet_address}"
  end

  def send_htg_payout(htg_amount, moncash_method)
    MoncashService.transfer(
      amount: htg_amount,
      receiver_phone: moncash_method.account_number
    )
    Rails.logger.info "SolOrchestrator: MonCash peman #{htg_amount} HTG -> #{moncash_method.masked_account_number}"
  end

  # ── Notifications ───────────────────────────────────────────────

  def send_payment_reminders(round)
    hours_left = ((round.created_at + GRACE_PERIOD_HOURS.hours - Time.current) / 1.hour).round
    hours_left = [hours_left, 1].max

    unpaid_members(round).each do |user_id|
      user = User.find(user_id)
      SolMailer.with(circle: @circle, round: round, user: user, hours_left: hours_left)
               .payment_reminder.deliver_later
    end
    Rails.logger.info "SolOrchestrator: Voye rapèl peman pou wonn #{round.round_number}"
  end

  def send_final_warnings(round, user_ids)
    user_ids.each do |user_id|
      user = User.find(user_id)
      SolMailer.with(circle: @circle, user: user).missed_payment.deliver_later
    end
    Rails.logger.warn "SolOrchestrator: Dènye avètisman pou #{user_ids.count} manm nan wonn #{round.round_number}"
  end
end

class CreditScoringService
  ON_TIME_PAYMENT   = 15
  COMPLETION_BONUS  = 50
  LATE_PENALTY      = -25
  DEFAULT_PENALTY   = -50

  # Award points for on-time payments after a round completes
  def self.update_for_round(round)
    round.sol_contributions.where(status: :paid).find_each do |contribution|
      adjust_score(contribution.user, ON_TIME_PAYMENT)
    end
  end

  # Bonus for completing an entire Sol circle
  def self.reward_completion(circle)
    circle.sol_memberships.active_members.find_each do |membership|
      adjust_score(membership.user, COMPLETION_BONUS)
    end
  end

  # Penalize a late payment (paid after grace period)
  def self.penalize_late_payment(user, _circle = nil)
    adjust_score(user, LATE_PENALTY)
  end

  # Penalize a default (removed from Sol entirely)
  def self.penalize_default(user, _circle = nil, reason: nil)
    adjust_score(user, DEFAULT_PENALTY)
  end

  private

  def self.adjust_score(user, delta)
    new_score = (user.credit_score || 0) + delta
    new_score = new_score.clamp(0, User::MAX_CREDIT_SCORE)
    user.update!(credit_score: new_score)
  end
end

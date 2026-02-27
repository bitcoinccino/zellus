class SolMembership < ApplicationRecord
  belongs_to :user
  belongs_to :sol_circle

  scope :active_members, -> { where(active: true) }

  def default!(reason: "Peman manke")
    update!(active: false, defaulted_at: Time.current)
    CreditScoringService.penalize_default(user, sol_circle, reason: reason)
  end
end

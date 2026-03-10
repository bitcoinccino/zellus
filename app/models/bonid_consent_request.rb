class BonidConsentRequest < ApplicationRecord
  belongs_to :user
  belongs_to :transfer

  enum :status, {
    pending:  "pending",
    approved: "approved",
    denied:   "denied",
    expired:  "expired"
  }

  validates :consent_token, :bonid, :reference_id, presence: true
  validates :consent_token, uniqueness: true
  validates :reference_id, uniqueness: true

  scope :active, -> { where(status: :pending).where("expires_at > ?", Time.current) }

  def timed_out?
    expires_at.present? && expires_at < Time.current
  end
end

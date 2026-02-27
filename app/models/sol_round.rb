class SolRound < ApplicationRecord
  belongs_to :sol_circle
  
  # This tells Rails: "Look for the payout_user_id, but find the person in the User table"
  belongs_to :payout_user, class_name: "User"
  
  # Link to the payments made for this specific round
  has_many :sol_contributions, dependent: :destroy
  has_many :payment_requests, dependent: :nullify
  
  # Map integers in DB to readable states
  enum :status, { 
    collecting: 0, 
    processing_payout: 1, 
    paid_out: 2, 
    failed: 3 
  }
  
  # Helper to find rounds currently accepting 'hands'
  scope :collecting, -> { where(status: :collecting) }
  
  validates :round_number, presence: true
end

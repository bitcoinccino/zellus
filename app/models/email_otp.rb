class EmailOtp < ApplicationRecord
  require "bcrypt"

  CODE_TTL     = 10.minutes
  MAX_ATTEMPTS = 5

  validates :email,       presence: true
  validates :code_digest, presence: true
  validates :expires_at,  presence: true

  scope :active, -> { where(consumed_at: nil).where("expires_at > ?", Time.current) }
  scope :for_email, ->(email) { where(email: email.to_s.downcase.strip) }

  def self.latest_active_for(email)
    for_email(email).active.order(created_at: :desc).first
  end

  def self.generate_for!(email, purpose: "login", ip: nil)
    code = format("%06d", SecureRandom.random_number(1_000_000))
    create!(
      email:           email.to_s.downcase.strip,
      code_digest:     BCrypt::Password.create(code),
      expires_at:      CODE_TTL.from_now,
      attempts:        0,
      consumed_at:     nil,
      last_request_ip: ip,
      purpose:         purpose
    )
    code
  end

  def expired?
    expires_at < Time.current
  end

  def consumed?
    consumed_at.present?
  end

  def exhausted?
    attempts >= MAX_ATTEMPTS
  end

  def verify!(submitted_code)
    return false if consumed? || expired? || exhausted?

    increment!(:attempts)

    if BCrypt::Password.new(code_digest) == submitted_code.to_s.strip
      update!(consumed_at: Time.current)
      true
    else
      false
    end
  end
end

class OauthToken < ApplicationRecord
  belongs_to :user
  belongs_to :oauth_client

  validates :access_token, uniqueness: true, allow_nil: true
  validates :authorization_code, uniqueness: true, allow_nil: true

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  before_create :generate_tokens

  def granted_scopes
    (scopes.to_s.split(/[\s,]+/) & OauthClient::VALID_SCOPES)
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def active?
    !expired? && !revoked?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def code_expired?
    code_expires_at.present? && code_expires_at < Time.current
  end

  # Exchange authorization code for access token
  def exchange_code!
    return false if code_expired? || access_token.present?

    update!(
      access_token: SecureRandom.hex(32),
      refresh_token: SecureRandom.hex(32),
      expires_at: 24.hours.from_now,
      authorization_code: nil,
      code_expires_at: nil
    )
    true
  end

  private

  def generate_tokens
    self.authorization_code ||= SecureRandom.hex(20)
    self.code_expires_at    ||= 10.minutes.from_now
  end
end

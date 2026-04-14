class OauthClient < ApplicationRecord
  has_many :oauth_tokens, dependent: :destroy
  has_many :webhook_deliveries, dependent: :destroy

  validates :name, :client_id, :client_secret, :redirect_uri, presence: true
  validates :client_id, uniqueness: true

  scope :active, -> { where(active: true) }
  scope :with_webhook, ->(event) { where(webhook_active: true).where("? = ANY(webhook_events)", event) }

  before_validation :generate_credentials, on: :create

  VALID_SCOPES = %w[
    openid profile email phone address
    physical health verification criminal_record
    balance:read transactions:read
    transfer:create withdraw:create
    checkout:create
  ].freeze

  def requested_scopes
    (scopes.to_s.split(/[\s,]+/) & VALID_SCOPES)
  end

  def valid_redirect_uri?(uri)
    redirect_uri == uri
  end

  private

  def generate_credentials
    self.client_id     ||= SecureRandom.hex(16)
    self.client_secret ||= SecureRandom.hex(32)
  end
end

# frozen_string_literal: true

# Thin routing module consulted by workers and controllers to decide
# whether to use Circle Programmable Wallets or the self-hosted
# Base L2 treasury for crypto operations.
#
# Controlled by ENV['CRYPTO_PROVIDER'] — flip to "self_hosted" at any
# time and the entire system reverts to the legacy path instantly.
module CryptoProvider
  def self.circle?
    CircleConfig.enabled? && CircleConfig.configured?
  end

  def self.self_hosted?
    !circle?
  end

  # Returns the USD deposit address for a user based on the active provider.
  # Circle-provisioned users show their Circle wallet address;
  # legacy users show the HMAC-derived deposit_address.
  def self.deposit_address_for(user)
    if circle? && user.circle_wallet_address.present?
      user.circle_wallet_address
    else
      user.deposit_address
    end
  end

  def self.provider_name
    circle? ? "circle" : "self_hosted"
  end
end

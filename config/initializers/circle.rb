# frozen_string_literal: true

module CircleConfig
  API_KEY        = ENV.fetch("CIRCLE_API_KEY", "")
  ENTITY_SECRET  = ENV.fetch("CIRCLE_ENTITY_SECRET", "")
  BASE_URL       = ENV.fetch("CIRCLE_API_URL", "https://api.circle.com")
  WALLET_SET_ID  = ENV.fetch("CIRCLE_WALLET_SET_ID", "")
  WEBHOOK_SECRET = ENV.fetch("CIRCLE_WEBHOOK_SECRET", "")
  BLOCKCHAIN     = ENV.fetch("CIRCLE_BLOCKCHAIN", "BASE-SEPOLIA") # BASE for mainnet, BASE-SEPOLIA for testnet

  # USD (USDC) contract address — differs per network
  # Base Mainnet: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
  # Base Sepolia: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
  USD_TOKEN_ADDRESS = ENV.fetch("CIRCLE_USDC_CONTRACT",
    BLOCKCHAIN == "BASE" ? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" : "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  )

  def self.enabled?
    ENV.fetch("CRYPTO_PROVIDER", "self_hosted") == "circle"
  end

  def self.configured?
    API_KEY.present? && ENTITY_SECRET.present? && WALLET_SET_ID.present?
  end
end

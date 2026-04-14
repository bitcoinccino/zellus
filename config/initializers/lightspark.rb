# frozen_string_literal: true

module LightsparkConfig
  GRID_CLIENT_ID          = ENV.fetch("GRID_CLIENT_ID", "")
  GRID_CLIENT_SECRET      = ENV.fetch("GRID_CLIENT_SECRET", "")
  GRID_API_URL            = ENV.fetch("GRID_API_URL", "https://api.lightspark.com/grid/2025-10-13")
  LIGHTSPARK_WEBHOOK_SECRET = ENV.fetch("LIGHTSPARK_WEBHOOK_SECRET", "")
  UMA_DOMAIN              = ENV.fetch("UMA_DOMAIN", "zellus.ht")
  GRID_PLATFORM_ACCOUNT_ID = ENV.fetch("GRID_PLATFORM_ACCOUNT_ID", "")

  def self.enabled?
    FeatureFlags.uma_receiving? && configured?
  end

  def self.configured?
    GRID_CLIENT_ID.present? && GRID_CLIENT_SECRET.present?
  end
end

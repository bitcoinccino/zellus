# config/initializers/feature_flags.rb
#
# Centralized feature flags for Zèllus.
# Flip these to enable/disable features across the entire app.
# For Côtes de Fer v1 launch, most merchant features are OFF.

module FeatureFlags
  # ── MERCHANT / NICE FEATURES ── (all OFF for Côtes de Fer v1)
  MERCHANT_FEATURES_ENABLED  = false  # master switch for Biznis storefront section
  BIZNIS_STOREFRONT          = false  # public business page + products
  QR_PAYMENTS                = false  # QR-based payment acceptance
  MERCHANT_DASHBOARD         = false  # merchant analytics / dashboard
  P2P_TRANSFERS              = true   # phone, $zellustag, email — all enabled
  BUSINESS_DIRECTORY         = false  # admin "Tout Biznis" tab

  # ── ADMIN / GROWTH CONTROLS ──
  INVITE_CODES_REQUIRED      = true   # require invite code to register
  ADMIN_ADVANCED_TOOLS       = true   # admin can generate codes, manage agents
  BULK_CREDIT                = false  # admin bulk credit wallet (turn on later)

  # ── REMITTANCE / UMA ──
  UMA_RECEIVING              = false  # inbound UMA payments via Lightspark Grid (enable when more providers support UMA)

  # ── Helper methods for views/controllers ──
  class << self
    def merchant_features?;       MERCHANT_FEATURES_ENABLED; end
    def biznis_storefront?;       BIZNIS_STOREFRONT; end
    def qr_payments?;             QR_PAYMENTS; end
    def merchant_dashboard?;      MERCHANT_DASHBOARD; end
    def p2p_transfers?;          P2P_TRANSFERS; end
    def business_directory?;      BUSINESS_DIRECTORY; end
    def invite_codes_required?;   INVITE_CODES_REQUIRED; end
    def admin_advanced_tools?;    ADMIN_ADVANCED_TOOLS; end
    def bulk_credit?;             BULK_CREDIT; end
    def uma_receiving?;            UMA_RECEIVING; end
  end
end

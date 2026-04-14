# frozen_string_literal: true

# ── Zèllus Brand Constants ──
# Single source of truth for brand name across the entire app.
# Usage: APP_BRAND, APP_BRAND_PAY, APP_BRAND_BANK
#
module AppBrand
  NAME       = "Zèllus"          # Main brand: emails, UI, notifications
  PAY        = "Zèllus Pay"      # Payment button label (immutable)
  BANK       = "Zèllus Bank"     # Loan / banking context
  MAILER_FROM = "Zèllus <no-reply@zellus.app>"
end

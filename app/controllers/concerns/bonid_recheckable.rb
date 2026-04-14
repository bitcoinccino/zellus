# frozen_string_literal: true

# BonID Recheckable — proactively re-validates BonID status with the API.
#
# Problem: If BonID revokes a user but the webhook fails or is delayed,
# the user remains "verified" on Zèllus until they manually visit /bonid_verification.
#
# Solution: Before sensitive actions (transfers, large payments), call
# `recheck_bonid!` which queries BonID API to confirm the user is still verified.
# Throttled to once per 15 minutes to avoid excessive API calls.
#
# Usage in controllers:
#   include BonidRecheckable
#   before_action :recheck_bonid!, only: [:create, :confirm]
#
module BonidRecheckable
  extend ActiveSupport::Concern

  private

  # Re-verify BonID status with the API. If revoked, clears all BonID fields.
  # Throttled: only checks if last check was > 15 minutes ago.
  # Returns true if user is still verified (or was never verified), false if revoked mid-session.
  def recheck_bonid!
    return true unless user_signed_in?
    return true unless current_user.bonid_verified?

    # Throttle: don't hammer BonID API
    if current_user.bonid_rechecked_at.present? && current_user.bonid_rechecked_at > 15.minutes.ago
      return true
    end

    result = BonIdService.check_status(current_user.bonid)

    if result[:success]
      if result[:verified]
        # Still verified — just update the recheck timestamp
        current_user.update_columns(bonid_rechecked_at: Time.current)
      else
        # BonID says NOT verified — revoke locally
        revoke_bonid_locally!(current_user, "API recheck: verified=false")
      end
    else
      # API error — check if it's an auth failure (revoked partner access)
      if result[:error]&.include?("Otorizasyon") || result[:error]&.include?("401")
        revoke_bonid_locally!(current_user, "API recheck: 401 auth failure")
      else
        # Network/transient error — don't revoke, just log and let through
        Rails.logger.warn "BonID recheck failed for user #{current_user.id}: #{result[:error]} — allowing through"
        current_user.update_columns(bonid_rechecked_at: Time.current)
      end
    end

    true
  end

  def revoke_bonid_locally!(user, reason)
    fallback_name = user.display_name

    user.update!(
      bonid: nil,
      bonid_verified_at: nil,
      bonid_first_name: nil,
      bonid_last_name: nil,
      bonid_photo_url: nil,
      bonid_street: nil,
      bonid_locality: nil,
      bonid_commune: nil,
      bonid_department: nil,
      bonid_country: nil,
      bonid_blood_type: nil,
      bonid_rechecked_at: nil
    )
    Rails.logger.warn "BonID REVOKED locally for user #{user.id} — reason: #{reason}"

    # ── Real-time push: notify user's browser instantly ──
    NotificationChannel.broadcast_to(user, {
      type: "bonid_revoked",
      display_name: fallback_name,
      message: "Aksè BonID ou te revoke. Tanpri re-verifye idantite'w."
    })
  end
end

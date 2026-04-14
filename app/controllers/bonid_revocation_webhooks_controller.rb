class BonidRevocationWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :require_cashtag!
  skip_before_action :authenticate_user! if method_defined?(:authenticate_user!)

  # POST /bonid_revocation_webhook
  # Called by BonID when a citizen revokes a partner's access.
  # Payload: { bonid: "VP-...", partner_id: "zellus", event: "partner_revoked" }
  def create
    bonid = params[:bonid].to_s.strip
    event = params[:event].to_s

    if bonid.blank?
      render json: { error: "bonid required" }, status: :bad_request
      return
    end

    user = find_user_by_bonid(bonid)

    unless user
      Rails.logger.warn "BonID revocation webhook: user not found for bonid=#{bonid}"
      head :ok # Don't reveal user existence
      return
    end

    case event
    when "partner_revoked"
      # Always clear ALL BonID fields — don't gate on bonid_verified?
      # This ensures revocation works even if data is in an inconsistent state.
      clear_bonid_verification!(user, bonid)

    when "partner_restored"
      # Never auto-verify — user must re-verify manually
      Rails.logger.info "BonID partner access restored for user #{user.id} (bonid: #{bonid}) — manual re-verification required"
    else
      Rails.logger.warn "BonID revocation webhook: unknown event '#{event}' for bonid=#{bonid}"
    end

    head :ok
  rescue => e
    Rails.logger.error "BonID revocation webhook error: #{e.message}"
    head :internal_server_error
  end

  private

  def find_user_by_bonid(bonid)
    # Try exact match first
    user = User.find_by(bonid: bonid)
    return user if user

    # Try partial match on suffix (BonID format: XX-YYYY-X-XXXXX-X-NNNN-NNN)
    if bonid.include?("-")
      suffix = bonid.split("-").last(2).join("-")
      user = User.where("bonid LIKE ?", "%-#{suffix}").first if suffix.present?
      return user if user
    end

    # Try by provider+uid as fallback
    User.find_by(provider: "bonid", uid: bonid)
  end

  def clear_bonid_verification!(user, bonid)
    # Capture display name before clearing BonID fields
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
    Rails.logger.info "BonID REVOKED for user #{user.id} (bonid: #{bonid}) — ALL verification fields cleared"

    # ── Real-time push: notify user's browser instantly ──
    NotificationChannel.broadcast_to(user, {
      type: "bonid_revoked",
      display_name: fallback_name,
      message: "Aksè BonID ou te revoke. Tanpri re-verifye idantite'w."
    })
    Rails.logger.info "BonID revocation broadcast sent to user #{user.id}"
  end
end

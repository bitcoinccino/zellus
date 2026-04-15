class BonidRevocationWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :require_cashtag!
  skip_before_action :authenticate_user! if method_defined?(:authenticate_user!)

  # POST /bonid_revocation_webhook
  # Called by BonID when a citizen revokes a partner's access.
  # BonID payload: { event: "consent.revoked", bonid: "MB-...", consent_id: 1, scopes: [...], data_erasure: {...}, timestamp: "..." }
  def create
    bonid = params[:bonid].to_s.strip
    event = params[:event].to_s

    Rails.logger.info "BonID webhook received: event=#{event}, bonid=#{bonid}, params=#{params.except(:controller, :action).to_unsafe_h}"

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
    when "consent.revoked", "partner_revoked"
      clear_bonid_verification!(user, bonid)

      # Handle data erasure request if present
      if params[:data_erasure].present? && params.dig(:data_erasure, :requested) == true
        Rails.logger.info "BonID data erasure requested for user #{user.id} (bonid: #{bonid})"
      end

    when "consent.restored", "partner_restored"
      # Never auto-verify — user must re-verify manually
      Rails.logger.info "BonID partner access restored for user #{user.id} (bonid: #{bonid}) — manual re-verification required"
    else
      Rails.logger.warn "BonID revocation webhook: unknown event '#{event}' for bonid=#{bonid}"
    end

    head :ok
  rescue => e
    Rails.logger.error "BonID revocation webhook error: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    head :internal_server_error
  end

  private

  def find_user_by_bonid(bonid)
    # Try exact match first
    user = User.find_by(bonid: bonid)
    return user if user

    # Try partial match on suffix (BonID format: XX-YYYY-X-XX-PNNNN-NNN)
    if bonid.include?("-")
      suffix = bonid.split("-").last(2).join("-")
      user = User.where("bonid LIKE ?", "%-#{suffix}").first if suffix.present?
      return user if user
    end

    # Try by provider+uid as fallback
    User.find_by(provider: "bonid", uid: bonid)
  end

  def clear_bonid_verification!(user, bonid)
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

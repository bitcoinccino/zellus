class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  # Allow OAuth callback even when user is already signed in (for BonID linking)
  skip_before_action :require_no_authentication, only: [:bonid], raise: false

  def bonid
    auth = request.env["omniauth.auth"]
    bonid_id = auth.info["bonid"] || auth.uid

    # ── Resolve canonical BonID from API ──
    begin
      api_result = BonIdService.lookup(bonid_id)
      bonid_id = api_result[:bonid] if api_result[:success] && api_result[:bonid].present?
    rescue => e
      Rails.logger.warn "BonID API lookup during OAuth failed: #{e.message}"
    end

    # ── Crime status check ──
    oauth_token = auth.credentials&.token
    check_crime_status!(bonid_id, oauth_token)

    # ── CASE 1: User is already signed in → linking BonID to current account ──
    if current_user
      # Check if this BonID is already linked to a DIFFERENT account
      existing = User.where(bonid: bonid_id).where.not(id: current_user.id).first
      if existing
        redirect_to bonid_verification_path,
          alert: "BonID sa a deja lye ak yon lòt kont Zèllus. Chak moun ka gen yon sèl kont."
        return
      end

      # Check if current user is already verified
      if current_user.bonid_verified?
        redirect_to bonid_verification_path, notice: "Ou deja verifye ak BonID."
        return
      end

      # Link BonID to current account
      identity = auth.info
      current_user.update!(
        bonid: bonid_id,
        bonid_verified_at: Time.current,
        bonid_first_name: identity["first_name"],
        bonid_last_name: identity["last_name"],
        bonid_photo_url: User.normalize_bonid_photo_url(identity["image"]),
        bonid_rechecked_at: Time.current,
        bonid_street: identity["street"],
        bonid_locality: identity["locality"],
        bonid_commune: identity["commune"],
        bonid_department: identity["department"],
        bonid_country: identity["country"],
        bonid_blood_type: identity["blood_type"]
      )

      redirect_to bonid_verification_path, notice: "Idantite'w verifye ak siksè! Limit kredi'w ogmante."
      return
    end

    # ── CASE 2: User is NOT signed in → sign in or create account ──
    @user = User.from_omniauth(auth)

    if @user.persisted?
      sign_in_and_redirect @user, event: :authentication
      set_flash_message(:notice, :success, kind: "BonID") if is_navigational_format?
    else
      session["devise.bonid_data"] = auth.except(:extra)
      redirect_to new_user_registration_url, alert: "Enskripsyon ak BonID echwe. Tanpri eseye ankò."
    end
  rescue User::CriminalRecordRestricted => e
    Rails.logger.warn "BonID criminal record restricted: #{e.bonid}"
    redirect_to new_user_session_path,
      alert: "Kont ou pa ka aktive pou kounye a. Tanpri kontakte sipò pou plis enfòmasyon."
  rescue User::RegionRestricted => e
    Rails.logger.warn "BonID region restricted: #{e.commune.inspect}"
    if e.commune.blank?
      redirect_to new_user_registration_url,
        alert: "Nou pa ka verifye adrès ou atravè BonID. Tanpri eseye ankò pita."
    else
      redirect_to new_user_registration_url,
        alert: "BonID ou montre ou nan #{e.commune}. Zèllus disponib nan Côtes-de-Fer sèlman pou kounye a."
    end
  end

  def failure
    redirect_to new_user_session_path, alert: "Otentifikasyon BonID echwe: #{failure_message}"
  end

  private

  def check_crime_status!(bonid_id, oauth_token)
    result = BonIdService.check_crime_status(bonid_id, oauth_token)

    if result[:success] && result[:has_criminal_record]
      Rails.logger.warn "BonID crime check POSITIVE: #{bonid_id} — severity: #{result[:severity_label]}, count: #{result[:involvement_count]}"
      raise User::CriminalRecordRestricted, bonid_id
    elsif !result[:success]
      Rails.logger.warn "BonID crime check FAILED for #{bonid_id}: #{result[:error]} — allowing through"
    else
      Rails.logger.info "BonID crime check CLEAR: #{bonid_id}"
    end
  end
end

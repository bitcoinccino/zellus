class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  def bonid
    auth = request.env["omniauth.auth"]
    @user = User.from_omniauth(auth)

    if @user.persisted?
      # ── Crime status check (dual auth: API key + OAuth token) ──
      bonid_id = auth.info["bonid"] || auth.uid
      oauth_token = auth.credentials&.token
      check_crime_status!(bonid_id, oauth_token)

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
      # API failure — allow through (graceful degradation)
      Rails.logger.warn "BonID crime check FAILED for #{bonid_id}: #{result[:error]} — allowing login"
    else
      Rails.logger.info "BonID crime check CLEAR: #{bonid_id}"
    end
  end
end

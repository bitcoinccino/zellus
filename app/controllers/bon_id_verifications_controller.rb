class BonIdVerificationsController < ApplicationController
  before_action :authenticate_user!

  def show
  end

  def create
    bonid = params[:bonid].to_s.strip

    if bonid.blank?
      flash.now[:alert] = "Tanpri antre BonID ou."
      render :show, status: :unprocessable_entity
      return
    end

    if current_user.bonid_verified?
      flash.now[:alert] = "Ou deja verifye ak BonID."
      render :show, status: :unprocessable_entity
      return
    end

    result = BonIdService.verify_user!(current_user, bonid)

    if result[:success]
      # ── Crime status check (API key only, no OAuth token in manual flow) ──
      crime_result = BonIdService.check_crime_status(bonid)

      if crime_result[:success] && crime_result[:has_criminal_record]
        Rails.logger.warn "BonID crime check POSITIVE (manual verify): #{bonid} — severity: #{crime_result[:severity_label]}"
        # Undo verification
        current_user.update!(bonid: nil, bonid_verified_at: nil, bonid_first_name: nil, bonid_last_name: nil, bonid_photo_url: nil)
        flash.now[:alert] = "Kont ou pa ka aktive pou kounye a. Tanpri kontakte sipò pou plis enfòmasyon."
        render :show, status: :unprocessable_entity
        return
      elsif !crime_result[:success]
        Rails.logger.warn "BonID crime check FAILED (manual verify) for #{bonid}: #{crime_result[:error]} — allowing through"
      else
        Rails.logger.info "BonID crime check CLEAR (manual verify): #{bonid}"
      end

      redirect_to bonid_verification_path, notice: "Idantite'w verifye ak siksè! Limit kredi'w ogmante."
    else
      flash.now[:alert] = result[:error]
      render :show, status: :unprocessable_entity
    end
  end
end

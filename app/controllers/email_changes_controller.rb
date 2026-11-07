# Second step of changing an account's email: prove control of the new address.
# Users::RegistrationsController has already checked the PIN and sent the code.
class EmailChangesController < ApplicationController
  before_action :authenticate_user!
  before_action :load_pending_email

  # GET /email_change
  def show
  end

  # POST /email_change
  def create
    result = OtpService.verify!(@email, params[:code].to_s)

    unless result.success?
      flash.now[:alert] = case result.error
      when :exhausted then "Twòp tès erè. Mande yon nouvo kòd."
      when :no_code   then "Pa gen kòd aktif. Mande yon nouvo kòd."
      else                 "Kòd la pa kòrèk. Eseye ankò."
      end
      render :show, status: :unprocessable_entity
      return
    end

    old_email = current_user.email
    current_user.update!(email: @email)
    current_user.hold_outgoing_funds!
    NotificationService.email_changed(current_user, old_email: old_email)
    session.delete(:pending_email)
    redirect_to edit_user_registration_path, notice: "Imèl ou chanje. Pou sekirite, retrè ak transfè yo bloke pandan 24 èdtan."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    session.delete(:pending_email)
    redirect_to edit_user_registration_path, alert: "Imèl sa a pa disponib."
  end

  private

  def load_pending_email
    @email = session[:pending_email]
    redirect_to edit_user_registration_path if @email.blank?
  end
end

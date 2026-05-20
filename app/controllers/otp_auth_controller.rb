# Email-OTP sign-in / sign-up. Replaces password-based authentication.
#
# Flow:
#   GET  /login          → email form
#   POST /login          → OtpService.request_for!(email) → redirect to verify
#   GET  /login/verify   → 6-digit code form
#   POST /login/verify   → OtpService.verify!(email, code)
#                          ├─ user exists → sign_in, route by next_onboarding_step
#                          └─ no user     → stash verified_email in session,
#                                           redirect to /onboarding/profile
class OtpAuthController < ApplicationController
  skip_before_action :require_cashtag!, raise: false
  before_action      :redirect_if_signed_in, only: %i[new create verify confirm]

  # GET /login
  def new
  end

  # POST /login — sends a code
  def create
    email  = params[:email].to_s
    result = OtpService.request_for!(email, ip: request.remote_ip)

    if result.success?
      session[:otp_email] = email.to_s.downcase.strip
      redirect_to login_verify_path, notice: "Nou voye yon kòd 6 chif nan #{session[:otp_email]}. Tcheke imèl ou."
    elsif result.error == :rate_limited
      session[:otp_email] = email.to_s.downcase.strip
      redirect_to login_verify_path, notice: "Yon kòd deja voye. Tann #{result.retry_after_seconds}s anvan ou mande yon lòt."
    else
      flash.now[:alert] = "Imèl la pa valid. Tanpri verifye epi eseye ankò."
      render :new, status: :unprocessable_entity
    end
  end

  # GET /login/verify
  def verify
    @email = session[:otp_email]
    redirect_to(login_path, alert: "Antre imèl ou anvan.") and return if @email.blank?
  end

  # POST /login/verify
  def confirm
    @email = session[:otp_email]
    redirect_to(login_path, alert: "Sesyon an ekspire. Eseye ankò.") and return if @email.blank?

    code   = params[:code].to_s
    result = OtpService.verify!(@email, code)

    unless result.success?
      flash.now[:alert] = case result.error
                         when :exhausted    then "Twòp tès erè. Mande yon nouvo kòd."
                         when :no_code      then "Pa gen kòd aktif. Mande yon nouvo kòd."
                         else                    "Kòd la pa kòrèk. Eseye ankò."
                         end
      render :verify, status: :unprocessable_entity
      return
    end

    user = User.find_by("LOWER(email) = ?", @email)

    if user.present?
      # Existing user — sign in, route by next onboarding step (if any).
      sign_in(user)
      session.delete(:otp_email)

      next_step = user.next_onboarding_step
      if next_step && session[:onboarding_user_id] == user.id
        redirect_to onboarding_step_path(next_step)
      else
        redirect_to after_sign_in_path_for(user)
      end
    else
      # New user — keep verified email in session, route to onboarding step 1.
      # Onboarding profile step will create the User row.
      session[:verified_email] = @email
      session.delete(:otp_email)
      redirect_to onboarding_profile_path
    end
  end

  private

  def redirect_if_signed_in
    return unless user_signed_in?
    redirect_to after_sign_in_path_for(current_user)
  end

  def after_sign_in_path_for(_resource)
    root_path
  end

  def onboarding_step_path(step)
    case step
    when :profile        then onboarding_profile_path
    when :pin            then onboarding_pin_path
    when :payment_method then onboarding_payment_method_path
    else                      root_path
    end
  end
end

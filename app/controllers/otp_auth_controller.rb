# Email-OTP sign-in / sign-up + post-login PIN unlock gate.
#
# Flow:
#   GET  /login          → email form
#   POST /login          → OtpService.request_for!(email) → redirect to verify
#   GET  /login/verify   → 6-digit code form
#   POST /login/verify   → OtpService.verify!(email, code)
#                          ├─ user exists → sign_in → /login/pin
#                          └─ no user     → stash verified_email → onboarding
#   GET  /login/pin      → PIN unlock gate (enter, or create if none yet)
#   POST /login/pin      → verify/create PIN → session[:pin_verified] → account
#
# OTP gets the session signed in; the PIN gate is a second factor that must
# pass before any app controller is reachable (enforced in ApplicationController
# via require_pin_unlock!). session[:pin_verified] dies with the session, so a
# fresh login always asks again.
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
      session[:otp_email]  = email.to_s.downcase.strip
      session[:otp_resent] = params[:resend].present?
      redirect_to login_verify_path
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
      # Existing user — sign in. A fresh login must re-pass the PIN gate.
      sign_in(user)
      session.delete(:otp_email)
      session.delete(:pin_verified)
      redirect_to login_pin_path
    else
      # New user — keep verified email in session, route to onboarding step 1.
      # Onboarding profile step will create the User row.
      session[:verified_email] = @email
      session.delete(:otp_email)
      redirect_to onboarding_profile_path
    end
  end

  # GET /login/pin — PIN unlock gate
  def pin
    redirect_to(login_path) and return unless user_signed_in?
    @needs_pin_setup = !current_user.has_transfer_pin?
    @pin_locked      = current_user.pin_locked?
  end

  # POST /login/pin
  def unlock
    redirect_to(login_path) and return unless user_signed_in?

    if current_user.pin_locked?
      @needs_pin_setup = false
      @pin_locked      = true
      flash.now[:alert] = pin_locked_message
      render :pin, status: :too_many_requests
    elsif current_user.has_transfer_pin?
      verify_existing_pin
    else
      create_pin
    end
  end

  # POST /login/pin/reset — email a fresh OTP to authorize a PIN reset
  def request_pin_reset
    redirect_to(login_path) and return unless user_signed_in?

    result = OtpService.request_for!(current_user.email, ip: request.remote_ip, purpose: "pin_reset")

    if result.success? || result.error == :rate_limited
      session[:pin_reset]  = true
      session[:otp_resent] = (result.error == :rate_limited)
      notice = result.error == :rate_limited ? "Yon kòd deja voye nan imèl ou." : "Nou voye yon kòd 6 chif nan imèl ou."
      redirect_to login_pin_reset_verify_path, notice: notice
    else
      redirect_to login_pin_path, alert: "Nou pa ka voye kòd la kounye a. Tanpri eseye ankò."
    end
  end

  # GET /login/pin/reset/verify — enter the 6-digit code to confirm the reset
  def pin_reset_verify
    redirect_to(login_path) and return unless user_signed_in?
    redirect_to(login_pin_path) and return unless session[:pin_reset]
    @email = current_user.email
  end

  # POST /login/pin/reset/verify — verify code, clear the PIN, route to setup
  def confirm_pin_reset
    redirect_to(login_path) and return unless user_signed_in?
    redirect_to(login_pin_path) and return unless session[:pin_reset]

    result = OtpService.verify!(current_user.email, params[:code].to_s)

    unless result.success?
      @email = current_user.email
      flash.now[:alert] = case result.error
                          when :exhausted then "Twòp tès erè. Mande yon nouvo kòd."
                          when :no_code   then "Pa gen kòd aktif. Mande yon nouvo kòd."
                          else                 "Kòd la pa kòrèk. Eseye ankò."
                          end
      render :pin_reset_verify, status: :unprocessable_entity
      return
    end

    # OTP confirmed control of the email — clear the PIN and the lockout so the
    # gate prompts for a fresh PIN on the next screen.
    current_user.transfer_pin = nil
    current_user.save!
    current_user.reset_pin_attempts!
    session.delete(:pin_reset)
    session.delete(:pin_verified)
    redirect_to login_pin_path, notice: "Kòd verifye. Tanpri kreye yon nouvo PIN."
  end

  private

  def verify_existing_pin
    if current_user.verify_transfer_pin(params[:pin].to_s.strip)
      current_user.reset_pin_attempts!
      session[:pin_verified] = true
      redirect_to post_pin_unlock_path
    elsif current_user.register_failed_pin_attempt!
      @needs_pin_setup = false
      @pin_locked      = true
      flash.now[:alert] = pin_locked_message
      render :pin, status: :too_many_requests
    else
      @needs_pin_setup = false
      remaining = current_user.pin_attempts_remaining
      flash.now[:alert] = "PIN pa kòrèk. #{remaining} tès ki rete."
      render :pin, status: :unprocessable_entity
    end
  end

  # Kreyòl notice shown while a lockout window is active.
  def pin_locked_message
    minutes = (current_user.pin_lock_remaining_seconds / 60.0).ceil
    "Twòp tès erè. Kont ou bloke pou #{minutes} minit. Ou ka reyinisyalize PIN ou ak imèl ou."
  end

  def create_pin
    @needs_pin_setup = true
    pin     = params[:pin].to_s.strip
    confirm = params[:pin_confirmation].to_s.strip

    if !pin.match?(/\A\d{4}\z/)
      flash.now[:alert] = "PIN dwe 4 chif."
      render :pin, status: :unprocessable_entity
    elsif pin != confirm
      flash.now[:alert] = "De PIN yo pa menm. Tanpri verifye epi eseye ankò."
      render :pin, status: :unprocessable_entity
    else
      current_user.transfer_pin = pin
      current_user.save!
      current_user.reset_pin_attempts!
      session[:pin_verified] = true
      redirect_to post_pin_unlock_path, notice: "PIN ou kreye avèk siksè. Byenveni!"
    end
  end

  def redirect_if_signed_in
    return unless user_signed_in?
    redirect_to after_sign_in_path_for(current_user)
  end

  def after_sign_in_path_for(_resource)
    root_path
  end

  # After the PIN gate: a fresh sign-up lands on Paramèt (to add a payment
  # method and finish their profile); a returning user goes to the app.
  def post_pin_unlock_path
    if session[:onboarding_user_id].to_i == current_user&.id
      session.delete(:onboarding_user_id)
      edit_user_registration_path
    else
      root_path
    end
  end
end

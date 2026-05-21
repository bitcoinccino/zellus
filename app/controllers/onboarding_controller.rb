# New-user onboarding — a single step: pick a $Zèllustag, which creates the
# account. PIN setup happens at the /login/pin gate; payment method is set
# from Paramèt (account settings). After this step the user is signed in and
# sent through the PIN gate, which lands fresh sign-ups on the settings page.
class OnboardingController < ApplicationController
  skip_before_action :require_cashtag!, raise: false

  before_action :require_verified_email_or_user

  # GET /onboarding/profile
  def profile
    @user = current_user || User.new(email: session[:verified_email])
  end

  # POST /onboarding/profile
  def update_profile
    if current_user
      @user = current_user
      @user.assign_attributes(profile_params)
      saved = @user.save
    else
      @user = User.new(profile_params.merge(email: session[:verified_email]))
      @user.password = SecureRandom.hex(32)  # unused; column needs a value
      saved = @user.save
      if saved
        sign_in(@user)
        session.delete(:verified_email)
        session[:onboarding_user_id] = @user.id  # PIN gate reads this → Paramèt
      end
    end

    if saved
      # Into the PIN gate. For a fresh sign-up it then lands on Paramèt.
      redirect_to login_pin_path
    else
      render :profile, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:user).permit(:cashtag, :raw_invite_code)
  end

  def require_verified_email_or_user
    return if user_signed_in?
    return if session[:verified_email].present?
    redirect_to login_path, alert: "Antre imèl ou anvan."
  end
end

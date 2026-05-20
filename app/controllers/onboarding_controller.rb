# 3-step new-user onboarding gate after OTP signup.
#
#   Step 1 (profile)        — cashtag + invite_code. Creates the User row,
#                             then signs them in. Open to verified-email
#                             sessions (no user yet).
#   Step 2 (pin)            — 4-digit transfer PIN + confirmation.
#   Step 3 (payment_method) — MonCash phone number. Sets users.phone_number
#                             AND creates an active PaymentMethod row.
#
# session[:verified_email]      — set by OtpAuthController#confirm when an
#                                 OTP'd email has no matching User. Cleared
#                                 once the User row is created in step 1.
# session[:onboarding_user_id]  — set after step 1. Drives the redirect-to-
#                                 next-step before_action for steps 2 & 3.
#                                 Cleared once step 3 completes.
class OnboardingController < ApplicationController
  skip_before_action :require_cashtag!, raise: false

  before_action :require_verified_email_or_user, only: %i[profile update_profile]
  before_action :authenticate_user!,              only: %i[pin update_pin payment_method update_payment_method]
  before_action :enforce_step_order,              only: %i[pin update_pin payment_method update_payment_method]

  # ── Step 1: Profile (cashtag + invite code) ─────────────────────────────
  def profile
    @user = current_user || User.new(email: session[:verified_email])
  end

  def update_profile
    if current_user
      @user = current_user
      @user.assign_attributes(profile_params)
      if @user.save
        redirect_to next_step_after(:profile)
      else
        render :profile, status: :unprocessable_entity
      end
    else
      @user = User.new(profile_params.merge(email: session[:verified_email]))
      @user.password = SecureRandom.hex(32)  # unused; column needs a value
      if @user.save
        sign_in(@user)
        session.delete(:verified_email)
        session[:onboarding_user_id] = @user.id
        redirect_to next_step_after(:profile)
      else
        render :profile, status: :unprocessable_entity
      end
    end
  end

  # ── Step 2: Transfer PIN ────────────────────────────────────────────────
  def pin
  end

  def update_pin
    raw     = params[:transfer_pin].to_s.strip
    confirm = params[:transfer_pin_confirmation].to_s.strip

    unless raw.match?(/\A\d{4}\z/)
      flash.now[:alert] = "PIN dwe 4 chif."
      render :pin, status: :unprocessable_entity and return
    end

    if raw != confirm
      flash.now[:alert] = "De PIN yo pa menm. Tanpri verifye epi eseye ankò."
      render :pin, status: :unprocessable_entity and return
    end

    current_user.transfer_pin = raw
    current_user.save!
    redirect_to next_step_after(:pin)
  end

  # ── Step 3: Payment method (MonCash) ────────────────────────────────────
  def payment_method
    @payment_method = current_user.payment_methods.build(
      category: "mobile_wallet",
      provider: "moncash"
    )
  end

  def update_payment_method
    phone = params.dig(:payment_method, :account_number).to_s.strip

    unless phone.match?(/\A509\d{8}\z/)
      flash.now[:alert] = "Nimewo MonCash dwe nan fòma 509 + 8 chif."
      @payment_method = current_user.payment_methods.build(
        category: "mobile_wallet",
        provider: "moncash",
        account_number: phone
      )
      render :payment_method, status: :unprocessable_entity and return
    end

    ActiveRecord::Base.transaction do
      current_user.update!(phone_number: phone)
      current_user.payment_methods.create!(
        category:    "mobile_wallet",
        provider:    "moncash",
        account_number: phone,
        is_default:  true,
        active:      true
      )
    end

    session.delete(:onboarding_user_id)
    redirect_to root_path, notice: "Bywenni sou Zèllus! Kont ou prèt."
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.record.errors.full_messages.first || "Pa ka anrejistre."
    @payment_method = current_user.payment_methods.build(
      category: "mobile_wallet",
      provider: "moncash",
      account_number: phone
    )
    render :payment_method, status: :unprocessable_entity
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

  # Prevents skipping ahead by URL. If the user is mid-onboarding (the
  # session flag is set) and tries to jump to a later step than they're
  # ready for, send them back to the earliest incomplete step.
  def enforce_step_order
    return unless session[:onboarding_user_id].to_i == current_user.id

    next_step = current_user.next_onboarding_step
    return if next_step.nil?

    expected_for_step = {
      pin:            :pin,
      update_pin:     :pin,
      payment_method: :payment_method,
      update_payment_method: :payment_method
    }
    expected = expected_for_step[action_name.to_sym]
    return if expected.nil? || expected == next_step

    redirect_to step_path(next_step)
  end

  def next_step_after(step)
    next_step = current_user&.next_onboarding_step
    return root_path if next_step.nil?
    step_path(next_step)
  end

  def step_path(step)
    case step
    when :profile        then onboarding_profile_path
    when :pin            then onboarding_pin_path
    when :payment_method then onboarding_payment_method_path
    else                      root_path
    end
  end
end

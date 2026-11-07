class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_permitted_parameters

  # Password signup is gone — funnel any POST /users to the OTP form.
  def create
    email = params.dig(:user, :email)
    redirect_to login_path(email: email), status: :see_other
  end

  # Override update to handle Turbo + non-password updates
  def update
    self.resource = resource_class.to_adapter.get!(send(:"current_#{resource_name}").to_key)
    prev_unconfirmed_email = resource.unconfirmed_email if resource.respond_to?(:unconfirmed_email)

    # Email never changes here: it controls login and PIN reset, so it goes
    # through EmailChangesController once the other fields are saved.
    requested_email = account_update_params[:email].to_s.strip.downcase
    resource_updated = update_resource(resource, account_update_params.except(:email))

    if resource_updated
      return if requested_email.present? && requested_email != resource.email.downcase && start_email_change(requested_email)

      set_flash_message_for_update(resource, prev_unconfirmed_email)
      bypass_sign_in resource, scope: resource_name if sign_in_after_change_password?
      redirect_to after_update_path_for(resource), status: :see_other
    else
      clean_up_passwords resource
      set_minimum_password_length
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_entity }
      end
    end
  end

  protected

  # Always redirects. Returns true so #update stops.
  def start_email_change(new_email)
    alert =
      if resource.pin_locked?
        "Kont ou bloke pou kounye a akòz twòp tès PIN."
      elsif !resource.verify_transfer_pin(params[:current_transfer_pin].to_s.strip)
        "PIN lan pa kòrèk. Imèl ou pa chanje."
      elsif !new_email.match?(User::EMAIL_FORMAT)
        "Imèl la pa valid."
      elsif User.where("LOWER(email) = ?", new_email).exists?
        "Imèl sa a deja itilize."
      end

    if alert
      redirect_to edit_user_registration_path, alert: alert, status: :see_other
      return true
    end

    result = OtpService.request_for!(new_email, ip: request.remote_ip, purpose: "email_change")
    if result.success? || result.error == :rate_limited
      session[:pending_email] = new_email
      redirect_to email_change_path, notice: "Nou voye yon kòd 6 chif nan nouvo imèl la.", status: :see_other
    else
      redirect_to edit_user_registration_path, alert: "Nou pa ka voye kòd la kounye a. Tanpri eseye ankò.", status: :see_other
    end
    true
  end


  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:account_update, keys: [
      :avatar, :email, :cashtag, :phone_number,
      :payout_preference, :auto_repay_enabled
    ])

    devise_parameter_sanitizer.permit(:sign_up, keys: [
      :first_name, :last_name, :email, :phone, :cashtag, :avatar,
      :raw_invite_code
    ])
  end

  # After sign up, redirect to wallet setup
  def after_sign_up_path_for(resource)
    setup_cashtag_path
  end

  # After updating account, stay on edit page
  def after_update_path_for(resource)
    edit_user_registration_path
  end

  # Update the account without a password — password sign-in is gone.
  # (Transfer PIN is updated separately via the Sekirite modal → set_pin.)
  def update_resource(resource, params)
    params.delete(:password)
    params.delete(:password_confirmation)
    params.delete(:current_password)
    resource.update(params)
  end
end

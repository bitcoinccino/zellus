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

    resource_updated = update_resource(resource, account_update_params)

    if resource_updated
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

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:account_update, keys: [
      :avatar, :email, :cashtag, :phone,
      :payout_preference, :auto_repay_enabled,
      :password, :password_confirmation, :current_password
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

  # Allow update without password for non-password fields
  def update_resource(resource, params)
    if params[:password].blank? && params[:password_confirmation].blank?
      params.delete(:password)
      params.delete(:password_confirmation)
      params.delete(:current_password)
      resource.update(params)
    else
      super
    end
  end
end

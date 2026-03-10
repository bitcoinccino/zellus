class Users::RegistrationsController < Devise::RegistrationsController
  protected

  # After sign up, redirect to wallet setup
  def after_sign_up_path_for(resource)
    setup_cashtag_path
  end

  # After updating account, stay on current page
  def after_update_path_for(resource)
    wallet_path
  end
end

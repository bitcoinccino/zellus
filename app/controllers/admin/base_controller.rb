class Admin::BaseController < ApplicationController
  layout "admin"
  before_action :authenticate_user!
  before_action :ensure_admin!
  before_action :reject_writes_during_hold

  private

  # The admin signs in with email and PIN like anyone else, so a PIN reset or
  # email change pauses admin actions too. Clearing it takes server access.
  def reject_writes_during_hold
    return if request.get? || request.head?

    reject_held_funds(admin_root_path)
  end


  def ensure_admin!
    admin_email = ENV['ADMIN_EMAIL'].to_s.strip
    unless current_user.email == admin_email
      redirect_to root_path, alert: "Authorized personnel only."
    end
  end
end

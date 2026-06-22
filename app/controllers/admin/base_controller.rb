class Admin::BaseController < ApplicationController
  layout "admin"
  before_action :authenticate_user!
  before_action :ensure_admin!

  private

  def ensure_admin!
    admin_email = ENV["ADMIN_EMAIL"].to_s.strip
    unless current_user.email == admin_email
      redirect_to root_path, alert: "Authorized personnel only."
    end
  end
end

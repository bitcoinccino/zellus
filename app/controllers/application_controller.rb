class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # ── Friendly error pages ──
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActionController::RoutingError, with: :render_not_found

  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :require_cashtag!, if: :user_signed_in?
  before_action :require_pin_unlock!, if: :user_signed_in?

  helper_method :incoming_request_count, :unread_notification_count, :recent_notifications_for_dropdown

  def incoming_request_count
    return 0 unless user_signed_in?

    @_incoming_request_count ||= PaymentRequest.incoming_for(current_user).count
  end

  def unread_notification_count
    return 0 unless user_signed_in?

    @_unread_notification_count ||= current_user.notifications.unread.count
  end

  def recent_notifications_for_dropdown
    return [] unless user_signed_in?

    @_recent_notifications ||= current_user.notifications.recent_first.limit(7)
  end

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:cashtag, :phone_number, :raw_invite_code])
    devise_parameter_sanitizer.permit(:account_update, keys: [:payout_preference, :cashtag, :phone_number, :auto_repay_enabled])
  end

  def after_sign_in_path_for(resource)
    stored = stored_location_for(resource)
    stored.present? && stored != "/" ? stored : wallet_path
  end

  def after_sign_up_path_for(resource)
    stored = stored_location_for(resource)
    stored.present? && stored != "/" ? stored : wallet_path
  end

  # Redirect existing users to pick a $cashtag if they don't have one
  def require_cashtag!
    return if devise_controller?
    return if controller_name == "users" && action_name.in?(%w[setup_cashtag save_cashtag check_cashtag])
    redirect_to setup_cashtag_path if current_user.cashtag.blank?
  end

  # Second factor: after OTP sign-in the session is authenticated but locked
  # until the user passes the PIN gate (OtpAuthController#pin). The flag lives
  # in the session, so every fresh login must re-unlock.
  def require_pin_unlock!
    return if devise_controller?
    return if controller_name.in?(%w[otp_auth onboarding])
    return if controller_name == "users" && action_name.in?(%w[setup_cashtag save_cashtag check_cashtag])
    return if session[:pin_verified]
    redirect_to login_pin_path
  end

  private

  def render_not_found
    render file: Rails.root.join("public", "404.html"), status: :not_found, layout: false, content_type: "text/html"
  end
end

# Override Devise's password sessions controller — we're OTP-only now.
#
# We leave #new alone so the existing marketing landing page (sessions/new.html.erb)
# still renders for unauthenticated users hitting /users/sign_in. Both
# #create and any password POST funnel users to the OTP form at /login,
# carrying the email they typed so it pre-fills.
class Users::SessionsController < Devise::SessionsController
  def create
    email = params.dig(:user, :email)
    redirect_to login_path(email: email), status: :see_other
  end
end

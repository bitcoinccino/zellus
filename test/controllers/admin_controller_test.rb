require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  # The admin area is gated by authentication + an admin-email check
  # (Admin::BaseController). An unauthenticated request must be redirected to
  # sign-in rather than rendering the dashboard.
  test "dashboard redirects unauthenticated users to sign in" do
    get admin_dashboard_url
    assert_redirected_to new_user_session_url
  end
end

require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  setup do
    # The admin is whoever's email matches ADMIN_EMAIL (Admin::BaseController).
    # Tests don't load .env, so set it to a fixture user.
    @original_admin_email = ENV["ADMIN_EMAIL"]
    @admin = users(:receiver)
    ENV["ADMIN_EMAIL"] = @admin.email
  end

  # Signed-in pages also require the PIN unlock (ApplicationController#require_pin_unlock!).
  def sign_in_with_pin(user)
    user.transfer_pin = "4827"
    user.save!
    login_as(user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  teardown do
    ENV["ADMIN_EMAIL"] = @original_admin_email
    Warden.test_reset!
  end

  test "admin can open the dashboard" do
    sign_in_with_pin(@admin)
    get admin_dashboard_url
    assert_response :success
  end

  test "signed-out visitor is sent to sign in" do
    get admin_dashboard_url
    assert_redirected_to new_user_session_url
  end

  test "non-admin user is turned away" do
    sign_in_with_pin(users(:sender))
    get admin_dashboard_url
    assert_redirected_to root_url
  end
end

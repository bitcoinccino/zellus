require "test_helper"

class MobileProfileMenuTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  teardown { Warden.test_reset! }

  test "signed-in navbar has the profile menu outside the collapse and no hamburger" do
    user = users(:receiver)
    user.transfer_pin = "4827"
    user.save!
    login_as(user, scope: :user)
    post login_pin_path, params: { pin: "4827" }

    get notifications_path

    assert_response :success
    assert_select ".navbar-toggler", count: 0
    assert_select "#zellusNavbarContent .profile-toggle", count: 0
    assert_select "nav.navbar .dropdown .profile-toggle", count: 1
    assert_select ".profile-toggle span.d-none.d-lg-inline", count: 1
    assert_select "#notif-bell-badge-m", count: 1
  end

  test "logged-out navbar keeps the hamburger" do
    get faq_path

    assert_response :success
    assert_select ".navbar-toggler", count: 1
    assert_select ".profile-toggle", count: 0
  end
end

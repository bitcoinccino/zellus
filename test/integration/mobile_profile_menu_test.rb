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
    # The button is avatar-only on every screen size; the $cashtag shows once,
    # in the menu header next to the name.
    assert_select ".profile-toggle", text: /\$#{user.cashtag}/, count: 0
    assert_select ".profile-menu .profile-menu-cashtag", text: "$#{user.cashtag}", count: 1
    # No Bootstrap caret: the avatar alone opens the menu.
    assert_select ".profile-toggle.dropdown-toggle", count: 0
    assert_select ".profile-toggle[data-bs-toggle=dropdown][aria-label]", count: 1
    assert_select "#notif-bell-badge-m", count: 1
  end

  test "logged-out navbar keeps the hamburger" do
    get faq_path

    assert_response :success
    assert_select ".navbar-toggler", count: 1
    assert_select ".profile-toggle", count: 0
  end
end

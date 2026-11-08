require "test_helper"

class WalletHeroMenuTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  setup do
    @user = users(:sender)
    @user.transfer_pin = "4827"
    @user.save!
  end

  teardown { Warden.test_reset! }

  # The ⋯ menu duplicates the desktop sidebar's Depoze / Konvèti / Retire,
  # so it only shows below the lg breakpoint (where the sidebar is hidden).
  test "the hero's three-dot menu is hidden on desktop" do
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
    get wallet_path

    assert_response :success
    assert_select "div.d-lg-none > #hero-menu-btn", count: 1
    assert_select "#user-sidebar.d-none.d-lg-flex a[href*='action_panel=deposit']"
  end
end

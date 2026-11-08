require "test_helper"

# The BonID page lists why to verify, using the real limits so the copy can't
# promise something the code doesn't enforce.
class BonidVerificationPageTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  setup do
    @user = users(:sender)
    @user.transfer_pin = "4827"
    @user.save!
  end

  teardown { Warden.test_reset! }

  def sign_in(user)
    login_as(user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  test "unverified user sees why to verify, locked, with the live thresholds" do
    @user.update!(bonid: nil, bonid_verified_at: nil)
    sign_in(@user)

    get bonid_verification_path

    assert_response :success
    assert_select "h1", "Verifye ak BonID"
    assert_includes response.body, "Poukisa pou w verifye?"
    assert_select ".verify-group-label", text: "Pi gwo limit"
    assert_select ".verify-group-label", text: "Pwoteksyon kont fwod"
    assert_select ".verify-reason", 4
    assert_select ".verify-reason .ri-lock-2-line", 4
    assert_select ".verify-reason .bonid-verified-icon", 4

    threshold = WalletLimitService.config[:bonid_withdrawal_threshold_htg].to_i
    assert_includes response.body, ActiveSupport::NumberHelper.number_to_delimited(threshold, delimiter: " ")
    assert_includes response.body, ActiveSupport::NumberHelper.number_to_delimited(BonIdService::CONSENT_THRESHOLD.to_i, delimiter: " ")
    assert_select "#bonid-connect-btn"
    refute_includes response.body, "PrioSòl"
  end

  test "verified user sees the same reasons marked active, without the connect button" do
    # A recent recheck keeps the page from calling the BonID API.
    @user.update!(bonid: "DL-1988-M-OU-P8697-C56", bonid_verified_at: Time.current,
                  bonid_rechecked_at: Time.current, bonid_first_name: "Test", bonid_last_name: "User")
    sign_in(@user)

    get bonid_verification_path

    assert_response :success
    assert_includes response.body, "Sa verifikasyon an ba ou"
    assert_select ".verify-reason", 4
    assert_select ".verify-reason .ri-checkbox-circle-fill", 4
    assert_select ".bonid-verified-icon--lg, .bonid-verified-badge"
    assert_select "#bonid-connect-btn", 0

    # The BonID number is masked everywhere on the page, including the menu.
    refute_includes response.body, "DL-1988-M-OU-P8697-C56"
    refute_includes response.body, "1988"
    assert_includes response.body, "DL-••••-•-••-•••••-C56"
  end
end

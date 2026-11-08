require "test_helper"

# "Konekte ak BonID" on the verification page goes through the OAuth flow in
# the same tab, after its loading steps. If BonID already knows the user (signed
# in, Zellus approved) it returns at once and the account is verified; otherwise
# BonID shows its own login first.
class BonidVerifyFlowTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  setup do
    OmniAuth.config.test_mode = true
    @saved_mocks = OmniAuth.config.mock_auth.dup
    OmniAuth.config.mock_auth[:bonid] = OmniAuth::AuthHash.new(
      provider: "bonid",
      uid: "2",
      info: { "bonid" => "DL-1990-F-OU-P1234-A12", "first_name" => "Flow", "last_name" => "Tester",
              "email" => "flow@example.com" },
      credentials: { "token" => "test-token" }
    )

    @user = users(:sender)
    @user.update!(bonid: nil, bonid_verified_at: nil)
    @user.transfer_pin = "4827"
    @user.save!
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  teardown do
    OmniAuth.config.mock_auth.replace(@saved_mocks)
    OmniAuth.config.test_mode = false
    Warden.test_reset!
  end

  test "verification page posts to the OAuth flow with its loading steps" do
    get bonid_verification_path

    assert_select "form#bonid-connect-form[action=?][method=post]", "/users/auth/bonid"
    assert_select "#bonid-loader"
    assert_includes response.body, "ZellusLoader.start('bonid-loader', form"
    refute_includes response.body, "otp_sign_in?from_partner=zellus"
    refute_includes response.body, "ZellusBonidPopup"
  end

  test "returning from BonID verifies the signed-in user and lands on the page" do
    post "/users/auth/bonid"
    follow_redirect! # mock request phase -> callback

    assert_redirected_to bonid_verification_path
    assert @user.reload.bonid_verified?
    follow_redirect!
    assert_includes response.body, "Idantite&#39;w verifye ak siksè"
  end
end

require "test_helper"
require "minitest/mock"

# BonID bills Zellus per identity lookup, so a BonID login must resolve the
# canonical BonID once — the callback used to look it up, then
# User.from_omniauth looked it up again.
class BonidLoginSingleLookupTest < ActionDispatch::IntegrationTest
  BONID = "DL-1990-F-OU-P1234-A12".freeze

  setup do
    OmniAuth.config.test_mode = true
    @saved_mocks = OmniAuth.config.mock_auth.dup
    OmniAuth.config.mock_auth[:bonid] = OmniAuth::AuthHash.new(
      provider: "bonid",
      uid: "2",
      info: { "bonid" => BONID, "first_name" => "Single", "last_name" => "Lookup",
              "email" => "single-lookup@example.com" },
      credentials: { "token" => "test-token" }
    )
    @user = users(:sender)
    @user.update!(bonid: BONID, bonid_verified_at: 1.day.ago)
  end

  teardown do
    OmniAuth.config.mock_auth.replace(@saved_mocks)
    OmniAuth.config.test_mode = false
  end

  test "signing in with BonID calls the BonID lookup API once" do
    calls = []
    fake_lookup = ->(bonid) { calls << bonid; { success: true, bonid: BONID } }

    BonIdService.stub(:lookup, fake_lookup) do
      post "/users/auth/bonid"
      follow_redirect! # mock request phase -> callback
    end

    assert_equal [ BONID ], calls
    assert_response :redirect
    refute_match %r{/users/sign_in|/users/sign_up}, response.location
  end
end

require "test_helper"

# Reloading a BonID callback URL reuses a one-time code, so OmniAuth hands the
# controller no auth hash. That must send the user back to sign in, not 500.
class BonidStaleCallbackTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @saved_mocks = OmniAuth.config.mock_auth.dup
    OmniAuth.config.mock_auth[:bonid] = nil
    OmniAuth.config.mock_auth[:default] = nil
  end

  teardown do
    OmniAuth.config.mock_auth.replace(@saved_mocks)
    OmniAuth.config.test_mode = false
  end

  test "callback without omniauth.auth redirects to sign in with a retry message" do
    get "/users/auth/bonid/callback", params: { code: "used-code", state: "old-state" }

    assert_redirected_to new_user_session_path
    assert_equal "Sesyon BonID la ekspire. Tanpri eseye ankò.", flash[:alert]
  end
end

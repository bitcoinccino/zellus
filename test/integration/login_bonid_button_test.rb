require "test_helper"

class LoginBonidButtonTest < ActionDispatch::IntegrationTest
  test "login page shows a blue Konekte ak BonID button posting to the OAuth flow" do
    get login_path

    assert_response :success
    assert_select "form#bonid-signin-form[action=?][method=post]", "/users/auth/bonid" do
      assert_select "button.btn-bonid", text: /Konekte ak BonID/
      assert_select "button.btn-bonid i.ri-shield-check-fill"
    end
    # The old charcoal/gold inline style is gone.
    refute_match(/background: var\(--haiti-charcoal\); color: var\(--haiti-gold\)/,
                 css_select("button.btn-bonid").first["style"].to_s)
  end
end

require "test_helper"

# The request page behind Peye: minimal info, and Refize available in every
# payer state (it used to be missing for ETH/wBTC requests).
class PaymentRequestPageTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  setup do
    @payer = users(:sender)
    @payer.transfer_pin = "4827"
    @payer.save!
    @requester = users(:receiver)
  end

  teardown { Warden.test_reset! }

  def make_request(**attrs)
    PaymentRequest.create!({
      user: @requester, payer: @payer, status: :active, asset: :htg,
      amount: 250, note: "Lajan lekòl", expires_at: 2.days.from_now
    }.merge(attrs))
  end

  def sign_in_payer
    login_as(@payer, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  test "shows who, amount, note, Peye and Refize — and nothing extra" do
    pr = make_request
    sign_in_payer
    get public_payment_request_path(pr.token)

    assert_response :success
    body = css_select(".rounded-4").first.text
    assert_includes body, "$#{@requester.cashtag}"
    assert_includes body, "250.00"
    assert_includes body, "Lajan lekòl"
    assert_match(/Ekspire nan 4\dh \d+m/, body.squish)
    assert_select "#pr-main", text: /Refize/
    assert_select "#pr-decline form[action=?]", decline_payment_request_path(pr.token)
    refute_includes body, pr.token.upcase      # no Ref line
    refute_includes body, "Ouvri Zèllus"
    refute_includes body, "Frè"
  end

  test "Refize is offered on ETH requests" do
    pr = make_request(asset: :eth, amount: 0.01)
    sign_in_payer
    get public_payment_request_path(pr.token)

    assert_select "#pr-decline form"
  end

  test "the requester sees no pay or decline controls" do
    pr = make_request
    login_as(@requester, scope: :user)
    get public_payment_request_path(pr.token)

    assert_select "#pr-main", count: 0
    assert_select "#pr-decline", count: 0
  end

  test "declining marks it declined and shows the reason" do
    pr = make_request
    sign_in_payer
    post decline_payment_request_path(pr.token), params: { decline_note: "Pa kounye a" }
    follow_redirect!

    assert pr.reload.declined?
    assert_includes response.body, "Demann sa a refize"
    assert_includes response.body, "Pa kounye a"
    assert_select "#pr-main", count: 0
  end
end

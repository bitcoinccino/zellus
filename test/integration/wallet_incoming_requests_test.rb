require "test_helper"

# Incoming payment requests sit under the main wallet card. A long note used to
# overflow the row and push the card sideways, and every request stacked up
# with no limit.
class WalletIncomingRequestsTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  LONG_NOTE = "Lajan pou lekòl timoun yo ak liv yo ak inifòm yo ak transpò pou tout ane a, mèsi anpil anpil zanmi".freeze

  setup do
    @user = users(:sender)
    @user.transfer_pin = "4827"
    @user.save!
    @requester = users(:receiver)
  end

  teardown { Warden.test_reset! }

  def create_requests(count)
    count.times do |i|
      PaymentRequest.create!(
        user: @requester, payer: @user, status: :active, asset: :htg,
        amount: 1_250_000 + i, note: (i.zero? ? LONG_NOTE : "Demann #{i + 1}"),
        expires_at: 2.days.from_now
      )
    end
  end

  def visit_wallet
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
    get wallet_path
    assert_response :success
  end

  test "shows the 3 most recent requests and tucks the rest behind a toggle" do
    create_requests(5)
    visit_wallet

    assert_select "#section-incoming .badge", text: "5"
    assert_select "#section-incoming .incoming-row", count: 5
    assert_select "#section-incoming details.incoming-more .incoming-row", count: 2
    assert_select "#section-incoming details.incoming-more summary", text: /Wè 2 lòt demann/
  end

  test "three or fewer requests show without a toggle" do
    create_requests(3)
    visit_wallet

    assert_select "#section-incoming .incoming-row", count: 3
    assert_select "#section-incoming details.incoming-more", count: 0
  end

  test "rows show only who's asking, the amount, and Peye — details live behind Peye" do
    create_requests(1)
    visit_wallet

    assert_select "#section-incoming .incoming-row", text: /\$#{@requester.cashtag}/
    assert_select "#section-incoming .incoming-row", text: /HTG 1,250,000/
    assert_select "#section-incoming .incoming-row a.btn", text: /Peye/
    refute_includes css_select("#section-incoming").text, LONG_NOTE
    refute_includes css_select("#section-incoming").text, "rete"
  end
end

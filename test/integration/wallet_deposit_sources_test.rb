require "test_helper"

# Depoze Lajan lists funding sources grouped as Lajan (MonCash) and Kripto
# (USD / wBTC / ETH on Base); each row opens that source's section.
class WalletDepositSourcesTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  setup do
    @user = users(:sender)
    @user.transfer_pin = "4827"
    @user.save!
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  teardown { Warden.test_reset! }

  test "deposit sources are grouped into Lajan and Kripto" do
    get wallet_path
    assert_response :success

    assert_select "#deposit-source-list .dep-group-label", text: "Lajan"
    assert_select "#deposit-source-list .dep-group-label", text: "Kripto"
    assert_select "#deposit-source-list .dep-group", count: 2

    lajan, kripto = css_select("#deposit-source-list .dep-group")
    assert_equal [ "MonCash" ], lajan.css(".dep-source-name").map(&:text)
    assert_equal [ "USD", "Bitcoin", "Ethereum" ], kripto.css(".dep-source-name").map(&:text)

    assert_select ".dep-source[onclick=?]", "selectDepositMethod('cash')"
    assert_select ".dep-source[onclick=?]", "selectDepositMethod('kripto', 'usd')"
  end

  test "Bitcoin and Ethereum are shown disabled while the flag is off" do
    skip "flag is on" if FeatureFlags.crypto_deposit_btc_eth?
    get wallet_path

    disabled = css_select("#deposit-source-list .dep-source-disabled")
    assert_equal [ "Bitcoin", "Ethereum" ], disabled.map { |d| d.at_css(".dep-source-name").text }
    disabled.each do |row|
      assert_nil row["onclick"]
      assert_equal "Byento", row.at_css(".dep-source-soon").text
    end
    %w[wbtc eth].each do |asset|
      assert_select ".dep-source[onclick=?]", "selectDepositMethod('kripto', '#{asset}')", count: 0
    end
  end

  test "source sections start hidden behind the list" do
    get wallet_path

    assert_select "#deposit-cash-section[style*='display: none']"
    assert_select "#deposit-kripto-section[style*='display: none']"
    assert_select "#deposit-back", count: 0
    assert_select "#dep-btn-cash", count: 0
  end
end

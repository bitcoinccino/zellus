require "test_helper"
require "minitest/mock"

class BonidWithdrawalGateTest < ActionDispatch::IntegrationTest
  include ApiTestHelper
  include Warden::Test::Helpers

  setup do
    @user = users(:sender)
    @wallet = wallets(:sender_wallet)
    @wallet.update!(htg_balance: 100_000, usdc_balance: 1_000)
    WalletLedgerEntry.where(wallet: @wallet).delete_all # fixtures include recent withdrawals
    setup_transfer_pin!(@user, "4827")
  end

  teardown { Warden.test_reset! }

  # ── The rule ──

  test "unverified user is allowed just below the threshold" do
    assert_not limits.bonid_required_for_withdrawal?(4_999)
  end

  test "unverified user is stopped at the threshold" do
    assert limits.bonid_required_for_withdrawal?(5_000)
  end

  test "verified user is never stopped" do
    verify_bonid!

    assert_not limits.bonid_required_for_withdrawal?(50_000)
  end

  test "splitting a withdrawal does not avoid the threshold" do
    ledger("withdrawal", 3_000)

    assert_not limits.bonid_required_for_withdrawal?(1_999)
    assert limits.bonid_required_for_withdrawal?(2_000)
  end

  test "fees count towards the total" do
    ledger("withdrawal", 4_900)
    ledger("instant_fee", 100)

    assert limits.bonid_required_for_withdrawal?(1)
  end

  test "withdrawals older than 24 hours do not count" do
    ledger("withdrawal", 4_900, created_at: 25.hours.ago)

    assert_not limits.bonid_required_for_withdrawal?(1_000)
  end

  test "USD withdrawals count at their HTG value" do
    RateService.stub(:usd_htg_rate, 100.0) do
      assert_not limits.bonid_required_for_withdrawal?(49, asset: "usd")
      assert limits.bonid_required_for_withdrawal?(50, asset: "usd")

      ledger("withdrawal", 40, asset: "usd")
      assert limits.bonid_required_for_withdrawal?(1_000)
    end
  end

  # ── Every live withdrawal path ──

  test "web MonCash withdrawal is sent to BonID without debiting" do
    sign_in_with_pin!

    assert_no_debit do
      post withdraw_wallet_path, params: { amount: 5_000, moncash_phone: "50912345678", transfer_pin: "4827" }
    end
    assert_redirected_to bonid_verification_path
  end

  test "web USD withdrawal is sent to BonID without debiting" do
    sign_in_with_pin!

    RateService.stub(:usd_htg_rate, 100.0) do
      assert_no_debit do
        post withdraw_usd_wallet_path, params: { amount: 50, wallet_address: "0x#{'a1b2c3d4e5' * 4}", transfer_pin: "4827" }
      end
    end
    assert_redirected_to bonid_verification_path
  end

  test "web bank withdrawal is sent to BonID without debiting" do
    sign_in_with_pin!

    assert_no_debit do
      post withdraw_bank_wallet_path, params: { amount: 5_000, bank_account_number: "123", account_holder_name: "Test", transfer_pin: "4827" }
    end
    assert_redirected_to bonid_verification_path
  end

  test "API withdrawal is refused for every method without debiting" do
    token = oauth_tokens(:sender_full_access).access_token

    [
      { amount: 5_000, asset: "htg", method: "moncash", phone: "50912345678" },
      { amount: 5_000, asset: "htg", method: "bank", bank_account: "123", account_holder: "Test" },
      { amount: 50, asset: "usd", method: "crypto", wallet_address: "0x#{'a1b2c3d4e5' * 4}" }
    ].each do |params|
      RateService.stub(:usd_htg_rate, 100.0) do
        assert_no_debit do
          post api_v1_withdrawals_url, params: params.merge(pin: "4827"), headers: api_auth_headers(token)
        end
      end
      assert_response :forbidden
      assert_includes parsed_response["error"], "BonID"
    end
  end

  test "API withdrawal below the threshold still goes through" do
    token = oauth_tokens(:sender_full_access).access_token

    post api_v1_withdrawals_url,
         params: { amount: 500, asset: "htg", method: "moncash", phone: "50912345678", pin: "4827" },
         headers: api_auth_headers(token)

    assert_response :created
  end

  private

  def limits
    WalletLimitService.new(@user.reload)
  end

  def verify_bonid!
    @user.update!(bonid: "BON-GATE-TEST", bonid_verified_at: Time.current)
  end

  def ledger(type, amount, asset: "htg", created_at: Time.current)
    @wallet.wallet_ledger_entries.create!(
      user: @user, entry_type: type, asset: asset, amount: amount,
      balance_after: 0, created_at: created_at
    )
  end

  def sign_in_with_pin!
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  def assert_no_debit
    assert_no_difference -> { @wallet.reload.wallet_ledger_entries.count } do
      yield
    end
  end
end

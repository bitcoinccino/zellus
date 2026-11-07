require "test_helper"
require "minitest/mock"

class UsdWithdrawalFeeTest < ActionDispatch::IntegrationTest
  include ApiTestHelper
  include Warden::Test::Helpers

  TREASURY = "0x#{'f' * 40}"
  ADDRESS  = "0x#{'a1b2c3d4e5' * 4}"

  setup do
    @user = users(:sender)
    @wallet = wallets(:sender_wallet)
    @wallet.update!(usdc_balance: 100)
    @user.update!(bonid: "BON-FEE-TEST", bonid_verified_at: Time.current)
    @user.transfer_pin = "4827"
    @user.save!

    # USD withdrawals check the platform reserve held in the admin's wallet.
    @original_admin_email = ENV["ADMIN_EMAIL"]
    ENV["ADMIN_EMAIL"] = users(:receiver).email
    wallets(:receiver_wallet).update!(usdc_balance: 100_000)
  end

  teardown do
    ENV["ADMIN_EMAIL"] = @original_admin_email
    Warden.test_reset!
  end

  test "the fee comes out of the amount: debit 50, recipient 48.51, fee 1.49" do
    WalletService.new(@wallet).withdraw!(amount: 50, asset: "usd")

    assert_equal BigDecimal("50"), BigDecimal("100") - @wallet.reload.usd_balance
    entry = WalletLedgerEntry.where(wallet: @wallet, entry_type: "withdrawal", asset: "usd").last
    assert_equal BigDecimal("48.51"), entry.amount
    fee = WalletLedgerEntry.where(wallet: @wallet, entry_type: "fee", asset: "usd").last
    assert_equal BigDecimal("1.49"), fee.amount
  end

  test "web withdrawal sends the recipient amount and passes the fee to the worker" do
    sign_in_with_pin!

    args = capture_worker do
      post withdraw_usd_wallet_path, params: { amount: 50, wallet_address: ADDRESS, transfer_pin: "4827" }
    end

    assert_redirected_to wallet_path
    assert_equal [ @user.id, "48.51", ADDRESS, "usd", "1.49" ], args
    assert_equal BigDecimal("50"), BigDecimal("100") - @wallet.reload.usd_balance
  end

  test "an amount that would leave the recipient less than 1 USD is refused" do
    sign_in_with_pin!

    assert_no_difference -> { WalletLedgerEntry.where(wallet: @wallet).count } do
      capture_worker { post withdraw_usd_wallet_path, params: { amount: 2.48, wallet_address: ADDRESS, transfer_pin: "4827" } }
    end
    assert_includes flash[:alert], "2.49"
  end

  test "the API reports the fee and payout" do
    args = capture_worker do
      post api_v1_withdrawals_url,
           params: { amount: 50, asset: "usd", method: "crypto", wallet_address: ADDRESS, pin: "4827" },
           headers: api_auth_headers(oauth_tokens(:sender_full_access).access_token)
    end

    assert_response :created
    assert_equal "1.49", parsed_response.dig("withdrawal", "fee")
    assert_equal "48.51", parsed_response.dig("withdrawal", "payout")
    assert_equal "48.51", args[1]
  end

  test "a failed send refunds the fee too" do
    WalletService.new(@wallet).withdraw!(amount: 50, asset: "usd")
    @user.update!(circle_wallet_id: "circle-test")

    CryptoProvider.stub(:circle?, true) do
      WalletUsdWithdrawWorker.new.perform(@user.id, "48.51", ADDRESS, "usd", "1.49")
    end

    assert_equal BigDecimal("100"), @wallet.reload.usd_balance
  end

  test "a successful send pays the recipient amount, not the amount entered" do
    WalletService.new(@wallet).withdraw!(amount: 50, asset: "usd")
    sent = nil
    worker = WalletUsdWithdrawWorker.new
    worker.define_singleton_method(:perform_self_hosted) { |_user, _wallet, amount, _to| sent = amount }

    CryptoProvider.stub(:circle?, false) do
      worker.perform(@user.id, "48.51", ADDRESS, "usd", "1.49")
    end

    assert_equal BigDecimal("48.51"), sent
    assert_equal BigDecimal("50"), BigDecimal("100") - @wallet.reload.usd_balance
  end

  test "Circle withdrawals call the method Circle actually has, with the recipient amount" do
    WalletService.new(@wallet).withdraw!(amount: 50, asset: "usd")
    @user.update!(circle_wallet_id: "circle-test")
    sent = nil
    send = lambda { |**kwargs| sent = kwargs[:amount]; { success: true, transaction_id: "c-1" } }

    CryptoProvider.stub(:circle?, true) do
      CircleService.stub(:send_usd, send) do
        WalletUsdWithdrawWorker.new.perform(@user.id, "48.51", ADDRESS, "usd", "1.49")
      end
    end

    assert_equal BigDecimal("48.51"), BigDecimal(sent.to_s)
  end

  test "jobs queued before the fee still refund what they debited" do
    WalletService.new(@wallet).withdraw!(amount: 50, asset: "usd")
    @user.update!(circle_wallet_id: "circle-test")

    CryptoProvider.stub(:circle?, true) do
      WalletUsdWithdrawWorker.new.perform(@user.id, 48.51, ADDRESS)
    end

    assert_equal BigDecimal("98.51"), @wallet.reload.usd_balance
  end

  test "the form shows the fee and the new minimum" do
    sign_in_with_pin!
    get wallet_path

    assert_response :success
    assert_select "#wd-usd-amount[min='2.49']"
    assert_select "#wd-review-fee-usd", count: 1
    assert_select "#wd-review-payout-usd", count: 1
    assert_includes response.body, "Frè: 1.49 USD"
  end

  private

  def sign_in_with_pin!
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  def capture_worker
    args = nil
    CryptoKeyHelper.stub(:treasury_address, TREASURY) do
      WalletUsdWithdrawWorker.stub(:perform_async, ->(*a) { args = a }) { yield }
    end
    args
  end
end

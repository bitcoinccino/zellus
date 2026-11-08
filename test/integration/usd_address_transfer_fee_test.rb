require "test_helper"
require "minitest/mock"

class UsdAddressTransferFeeTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  ADDRESS = "0x#{'a1b2c3d4e5' * 4}"

  setup do
    @user = users(:sender)
    @wallet = wallets(:sender_wallet)
    @wallet.update!(usdc_balance: 100)
    @user.transfer_pin = "4827"
    @user.save!
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  teardown { Warden.test_reset! }

  test "confirming debits the amount, records the fee and leaves the rest for the recipient" do
    transfer = usd_address_transfer(usd: 5)

    confirm(transfer)

    assert_equal BigDecimal("5"), BigDecimal("100") - @wallet.reload.usd_balance
    assert_equal BigDecimal("1.49"), transfer.reload.usd_network_fee_charged
    assert_equal BigDecimal("3.51"), transfer.crypto_payout_amount
    assert_equal BigDecimal("5"), transfer.crypto_amount, "refunds use the full amount debited"
  end

  test "an amount below the minimum is refused without debiting" do
    transfer = usd_address_transfer(usd: 2)

    assert_no_difference -> { WalletLedgerEntry.where(wallet: @wallet).count } do
      confirm(transfer)
    end
    assert_includes flash[:alert], "2.49"
    assert transfer.reload.pending?
  end

  test "the payout sends the amount minus the fee" do
    transfer = usd_address_transfer(usd: 5)
    confirm(transfer)
    @user.update!(circle_wallet_id: "circle-test")
    sent = nil
    send = lambda { |**kwargs| sent = kwargs[:amount]; { success: true, transaction_id: "c-1" } }

    CryptoProvider.stub(:circle?, true) do
      CircleService.stub(:send_usd, send) do
        TransferPayoutWorker.new.perform(transfer.id)
      end
    end

    assert_equal BigDecimal("3.51"), BigDecimal(sent.to_s)
  end

  test "a failed send leaves the transfer funded for a retry, with nothing paid out" do
    transfer = usd_address_transfer(usd: 5)
    confirm(transfer)
    @user.update!(circle_wallet_id: "circle-test")

    # A Circle failure must not fall back to the treasury: the "failure" can be
    # a lost response to a send Circle made, so a second send could pay twice.
    # The transfer stays funded and StuckTransferMonitorWorker retries via Circle.
    treasury_used = false
    CryptoProvider.stub(:circle?, true) do
      CircleService.stub(:send_usd, { success: false, error: "boom" }) do
        worker = TransferPayoutWorker.new
        worker.stub(:process_crypto_payout_self_hosted, ->(*) { treasury_used = true }) do
          worker.perform(transfer.id)
        end
      end
    end

    assert_not treasury_used, "a Circle failure must not send from the treasury"
    assert_includes transfer.reload.failure_reason.to_s, "boom"
    assert transfer.funded?
    assert_nil transfer.blockchain_tx_hash
    assert_equal BigDecimal("95"), @wallet.reload.usd_balance
  end

  test "giving up on a transfer refunds the fee too" do
    transfer = usd_address_transfer(usd: 5)
    confirm(transfer)

    TransferPayoutWorker.new.send(:mark_failed_and_refund!, transfer.reload, "test")

    assert_equal BigDecimal("100"), @wallet.reload.usd_balance
  end

  test "transfers from before the fee pay out their full amount" do
    transfer = usd_address_transfer(usd: 5)

    assert_equal BigDecimal("5"), transfer.crypto_payout_amount
  end

  test "the transfer page shows the fee and what the recipient gets" do
    transfer = usd_address_transfer(usd: 5)

    get transfer_path(transfer)

    assert_response :success
    assert_includes response.body, "Frè rezo: 1.49 USD"
    assert_includes response.body, "3.51 USD"
  end

  private

  def usd_address_transfer(usd:)
    @user.transfers.create!(
      asset: "usd", amount: usd * 100, exchange_rate: 100, crypto_amount: usd,
      receiver_wallet_address: ADDRESS, note: "x", status: :pending
    )
  end

  def confirm(transfer)
    TransferPayoutWorker.stub(:perform_async, nil) do
      post confirm_transfer_path(transfer), params: { transfer_pin: "4827", funding_source: "wallet" }
    end
  end
end

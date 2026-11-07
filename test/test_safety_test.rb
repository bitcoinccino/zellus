require "test_helper"

# Guards against tests moving real money. If one of these fails, do not run the
# rest of the suite until it passes.
class TestSafetyTest < ActiveSupport::TestCase
  test "no secret credentials are visible to tests" do
    present = TestSafety::SECRET_VARIABLES.select { |name| ENV[name].present? }

    assert_empty present, "secrets reached the test process: #{present.join(', ')}"
  end

  test "keys copied at boot are empty" do
    assert_empty CircleConfig::API_KEY
    assert_empty CircleConfig::ENTITY_SECRET
    assert_nil CryptoKeyHelper.treasury_address
  end

  test "the configured RPC points nowhere" do
    assert_equal TestSafety::UNREACHABLE_RPC, ENV["BASE_RPC_URL"]
  end

  test "outbound HTTP is blocked, including the public Base RPC fallbacks" do
    [ "https://mainnet.base.org", *BaseRpcClient::FALLBACK_URLS ].each do |url|
      assert_raises(TestNetworkGuard::BlockedError, url) { Net::HTTP.get(URI(url)) }
    end
  end

  test "an RPC call never leaves the machine" do
    error = assert_raises(StandardError) { BaseRpcClient.new.call("eth_blockNumber") }

    assert_no_match(/0x[0-9a-f]+/, error.message.to_s)
  end

  test "a USD payout cannot sign or broadcast" do
    transfer = users(:sender).transfers.create!(
      asset: "usd", amount: 500, exchange_rate: 100, crypto_amount: 5,
      receiver_wallet_address: "0x#{'a1b2c3d4e5' * 4}", note: "x", status: :funded, funding_source: "wallet"
    )

    TransferPayoutWorker.new.perform(transfer.id) rescue nil

    assert_nil transfer.reload.blockchain_tx_hash
    assert_not transfer.sent?
  end
end

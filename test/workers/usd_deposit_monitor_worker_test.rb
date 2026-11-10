require "test_helper"
require "minitest/mock"

class UsdDepositMonitorWorkerTest < ActiveSupport::TestCase
  HEAD    = 1_000_000
  USD     = UsdDepositMonitorWorker::USD_ADDRESS
  TOPIC   = UsdDepositMonitorWorker::TRANSFER_TOPIC
  ADDRESS = "0x#{'b' * 40}"

  # Records every eth_getLogs range and returns deposits that fall inside it.
  # max_range: reject eth_getLogs wider than this, like capped RPC providers.
  # hint: include the "this block range should work: [0x.., 0x..]" suggestion.
  class FakeRpc
    attr_reader :ranges, :rejected

    def initialize(deposits, max_range: nil, hint: true, error: nil)
      @deposits = deposits
      @ranges = []
      @rejected = []
      @max_range = max_range
      @hint = hint
      @error = error
    end

    def call(method, params = [])
      return "0x#{HEAD.to_s(16)}" if method == "eth_blockNumber"
      raise BaseRpcClient::RpcError, @error if @error

      from = params[0][:fromBlock].to_i(16)
      to = params[0][:toBlock].to_i(16)
      if @max_range && (to - from + 1) > @max_range
        @rejected << (from..to)
        msg = "RPC error (eth_getLogs): {\"code\"=>-32600, \"message\"=>\"You can make eth_getLogs requests with up to a #{@max_range} block range."
        msg += " Based on your parameters, this block range should work: [0x#{from.to_s(16)}, 0x#{(from + @max_range - 1).to_s(16)}]" if @hint
        raise BaseRpcClient::RpcError, msg + "\"}"
      end
      @ranges << (from..to)
      @deposits.select { |d| (from..to).cover?(d[:block]) }.map { |d| log(d) }
    end

    private

    def log(deposit)
      {
        "transactionHash" => deposit[:hash], "blockNumber" => "0x#{deposit[:block].to_s(16)}",
        "address" => USD,
        "topics" => [ TOPIC, "0x#{'e' * 64}", "0x#{ADDRESS.delete_prefix('0x').rjust(64, '0')}" ],
        "data" => "0x#{(deposit[:usd] * 1_000_000).to_i.to_s(16).rjust(64, '0')}"
      }
    end
  end

  setup do
    @user = users(:sender)
    @user.update!(deposit_address: ADDRESS)
    @wallet = @user.ensure_wallet!
    BlockchainDepositMonitor.where(name: UsdDepositMonitorWorker::MONITOR_NAME).delete_all
  end

  test "a monitor with no progress starts about a week back, not at the head" do
    rpc = run_monitor([])

    assert_equal HEAD - UsdDepositMonitorWorker::BACKFILL_BLOCKS, rpc.ranges.first.begin
  end

  test "a deposit made days before the monitor's first run is found as it catches up" do
    old_block = HEAD - 100_000
    deposits = [ { block: old_block, hash: "0x#{'1' * 64}", usd: 1 } ]

    until monitor_position >= old_block
      run_monitor(deposits)
    end

    assert_equal 1, credited("0x#{'1' * 64}").count
  end

  test "an explicit start block wins" do
    rpc = with_env("USD_DEPOSIT_MONITOR_START_BLOCK" => (HEAD - 500).to_s) { run_monitor([]) }

    assert_equal HEAD - 500, rpc.ranges.first.begin
  end

  test "saved progress still continues where it left off" do
    BlockchainDepositMonitor.create!(name: UsdDepositMonitorWorker::MONITOR_NAME, last_processed_block: HEAD - 50)

    rpc = run_monitor([])

    assert_equal HEAD - 49, rpc.ranges.first.begin
  end

  test "rescanning the same blocks never credits a deposit twice" do
    deposits = [ { block: HEAD - 10, hash: "0x#{'2' * 64}", usd: 3 } ]
    BlockchainDepositMonitor.create!(name: UsdDepositMonitorWorker::MONITOR_NAME, last_processed_block: HEAD - 100)

    run_monitor(deposits)
    BlockchainDepositMonitor.find_by(name: UsdDepositMonitorWorker::MONITOR_NAME).update!(last_processed_block: HEAD - 100)
    run_monitor(deposits)

    assert_equal 1, credited("0x#{'2' * 64}").count
    assert_equal BigDecimal("3"), credited("0x#{'2' * 64}").sum(:amount)
  end

  test "an RPC that caps eth_getLogs at 10 blocks no longer stalls the monitor" do
    BlockchainDepositMonitor.create!(name: UsdDepositMonitorWorker::MONITOR_NAME, last_processed_block: HEAD - 100)
    deposits = [ { block: HEAD - 95, hash: "0x#{'3' * 64}", usd: 5 } ]

    rpc = run_monitor(deposits, max_range: 10)

    assert_equal [ (HEAD - 99)..(HEAD - 90) ], rpc.ranges
    assert_equal HEAD - 90, monitor_position
    assert_equal 1, credited("0x#{'3' * 64}").count
  end

  test "without a suggested range it halves until the RPC accepts" do
    BlockchainDepositMonitor.create!(name: UsdDepositMonitorWorker::MONITOR_NAME, last_processed_block: HEAD - 1000)

    rpc = run_monitor([], max_range: 10, hint: false)

    # 200 → 100 → 50 → 25 → 12 → 6
    assert_equal [ 200, 100, 50, 25, 12 ], rpc.rejected.map(&:size)
    assert_equal 6, rpc.ranges.first.size
    assert_equal HEAD - 1000 + 6, monitor_position
  end

  test "other RPC errors still stop the run without moving progress" do
    BlockchainDepositMonitor.create!(name: UsdDepositMonitorWorker::MONITOR_NAME, last_processed_block: HEAD - 100)

    run_monitor([], error: "RPC error (eth_getLogs): {\"code\"=>-32000, \"message\"=>\"execution reverted\"}")

    assert_equal HEAD - 100, monitor_position
  end

  test "a deposit sends one notification and the hourly throttle counts deposit notifications" do
    BlockchainDepositMonitor.create!(name: UsdDepositMonitorWorker::MONITOR_NAME, last_processed_block: HEAD - 100)
    deposits = [ { block: HEAD - 50, hash: "0x#{'4' * 64}", usd: 2 } ]

    assert_difference -> { @user.notifications.where(notification_type: "deposit_confirmed").count }, 1 do
      run_monitor(deposits)
    end

    UsdDepositMonitorWorker::DEPOSIT_RATE_LIMIT.times do |i|
      NotificationService.crypto_deposit_received(@user, 1, "usd", "0x#{i.to_s.rjust(64, 'a')}")
    end
    BlockchainDepositMonitor.find_by(name: UsdDepositMonitorWorker::MONITOR_NAME).update!(last_processed_block: HEAD - 100)
    deposits << { block: HEAD - 40, hash: "0x#{'5' * 64}", usd: 2 }

    assert_no_difference -> { @user.notifications.where(notification_type: "deposit_confirmed").count } do
      run_monitor(deposits)
    end
    assert_equal 1, credited("0x#{'5' * 64}").count, "throttling skips the notification, never the credit"
  end

  private

  def run_monitor(deposits, **rpc_opts)
    Rails.cache.delete(UsdDepositMonitorWorker::RANGE_CACHE_KEY)
    rpc = FakeRpc.new(deposits, **rpc_opts)
    BaseRpcClient.stub(:new, ->(**) { rpc }) do
      UsdDepositMonitorWorker.stub(:perform_async, nil) do
        UsdDepositMonitorWorker.stub(:perform_in, nil) do
          UsdDepositMonitorWorker.new.perform
        end
      end
    end
    rpc
  end

  def monitor_position
    BlockchainDepositMonitor.find_by(name: UsdDepositMonitorWorker::MONITOR_NAME)&.last_processed_block.to_i
  end

  def credited(tx_hash)
    WalletLedgerEntry.where(wallet: @wallet, entry_type: "deposit", asset: "usd", moncash_transaction_id: tx_hash)
  end

  def with_env(vars)
    old = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

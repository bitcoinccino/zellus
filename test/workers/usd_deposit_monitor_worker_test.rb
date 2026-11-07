require "test_helper"
require "minitest/mock"

class UsdDepositMonitorWorkerTest < ActiveSupport::TestCase
  HEAD    = 1_000_000
  USD     = UsdDepositMonitorWorker::USD_ADDRESS
  TOPIC   = UsdDepositMonitorWorker::TRANSFER_TOPIC
  ADDRESS = "0x#{'b' * 40}"

  # Records every eth_getLogs range and returns deposits that fall inside it.
  class FakeRpc
    attr_reader :ranges

    def initialize(deposits)
      @deposits = deposits
      @ranges = []
    end

    def call(method, params = [])
      return "0x#{HEAD.to_s(16)}" if method == "eth_blockNumber"

      from = params[0][:fromBlock].to_i(16)
      to = params[0][:toBlock].to_i(16)
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

  private

  def run_monitor(deposits)
    rpc = FakeRpc.new(deposits)
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

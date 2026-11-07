require "test_helper"
require "minitest/mock"

class SellTransferWorkerTest < ActiveSupport::TestCase
  TREASURY = "0x9bac1ac641d7c08cae0f524cc62a81c6abe73dea"
  USD      = UsdDepositMonitorWorker::USD_ADDRESS
  TOPIC    = UsdDepositMonitorWorker::TRANSFER_TOPIC

  # Answers RPC calls from canned data.
  class FakeRpc
    def initialize(receipt:, block_time:)
      @receipt = receipt
      @block_time = block_time
    end

    def call(method, _params = [])
      method == "eth_getTransactionReceipt" ? @receipt : { "timestamp" => "0x#{@block_time.to_i.to_s(16)}" }
    end
  end

  setup do
    @user = users(:sender)
    @sell = sell_order
  end

  test "a real deposit to the treasury pays out" do
    assert run_worker(receipt(usd_log))

    assert @sell.reload.completed?
  end

  test "a successful transaction with no USD transfer does not pay out" do
    assert_not run_worker(receipt([]))

    assert @sell.reload.failed?
  end

  test "a deposit to another address does not pay out" do
    assert_not run_worker(receipt(usd_log(to: "0x#{'b' * 40}")))
  end

  test "a transfer of a different token does not pay out" do
    assert_not run_worker(receipt(usd_log(token: "0x#{'c' * 40}")))
  end

  test "a transfer event of a different kind does not pay out" do
    assert_not run_worker(receipt(usd_log(topic: "0x#{'d' * 64}")))
  end

  test "a deposit below the order amount does not pay out" do
    assert_not run_worker(receipt(usd_log(amount: 9_999_999)))
  end

  test "a deposit above the order amount pays out" do
    assert run_worker(receipt(usd_log(amount: 11_000_000)))
  end

  test "a hash already used by another order does not pay out, whatever its case" do
    sell_order(hash: @sell.blockchain_tx_hash.upcase.sub("0X", "0x"), status: :completed)

    assert_not run_worker(receipt(usd_log))
  end

  test "a deposit made before the order does not pay out" do
    assert_not run_worker(receipt(usd_log), block_time: @sell.created_at - 1.hour)
  end

  test "a reverted transaction does not pay out" do
    assert_not run_worker(receipt(usd_log, status: "0x0"))
  end

  test "a loan repayment needs a real deposit too" do
    loan = @user.transactions.create!(transaction_type: :loan_request, crypto_currency: :usd, crypto_amount: 10,
                                      fiat_amount: 1000, exchange_rate: 100, moncash_phone: "50912345678",
                                      destination_address: TREASURY, status: :crypto_sent,
                                      loan_purpose: Transaction::LOAN_PURPOSES.keys.first, repayment_term_weeks: 4)
    @sell.update!(failure_reason: "REPAYMENT_LOAN_#{loan.id}")

    run_worker(receipt([]))

    assert_not loan.reload.completed?
    assert @sell.reload.failed?
  end

  private

  def sell_order(hash: "0x#{SecureRandom.hex(32)}", status: :crypto_sent)
    @user.transactions.create!(
      transaction_type: :sell, crypto_currency: :usd, crypto_amount: 10, fiat_amount: 1300, fee_amount: 27,
      exchange_rate: 132.7, moncash_phone: "50912345678", destination_address: TREASURY,
      blockchain_tx_hash: hash, status: status
    )
  end

  def usd_log(to: TREASURY, token: USD, topic: TOPIC, amount: 10_000_000)
    [ {
      "address" => token,
      "topics" => [ topic, "0x#{'e' * 64}", "0x#{to.delete_prefix('0x').rjust(64, '0')}" ],
      "data" => "0x#{amount.to_s(16).rjust(64, '0')}"
    } ]
  end

  def receipt(logs, status: "0x1")
    { "status" => status, "blockNumber" => "0x1", "logs" => logs }
  end

  # Runs the worker and returns whether MonCash was asked to pay.
  def run_worker(receipt, block_time: 1.minute.from_now)
    paid = false
    payout = lambda { |*_args| paid = true; { success: true, transaction_id: "MC-1" } }

    rpc = FakeRpc.new(receipt: receipt, block_time: block_time)
    BaseRpcClient.stub(:new, ->(**) { rpc }) do
      MoncashService.stub(:customer_status, { success: true, active: true }) do
        MoncashService.stub(:transfert, payout) do
          SellTransferWorker.new.perform(@sell.id)
        end
      end
    end
    paid
  end
end

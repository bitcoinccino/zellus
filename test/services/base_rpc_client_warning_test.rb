require "test_helper"

# BASE_RPC_URL set to a website (it was "https://base.org") answers with HTML,
# so every call silently fell back to the public RPC. The client now says so.
class BaseRpcClientWarningTest < ActiveSupport::TestCase
  WEBSITE = "https://not-an-rpc.test"

  setup { BaseRpcClient.warned_urls.clear }

  test "a primary URL that returns non-JSON logs a clear BASE_RPC_URL error once" do
    client = BaseRpcClient.new(url: WEBSITE)
    logged = capture_errors do
      client.stub(:sleep, nil) do
        client.stub(:execute, ->(url, *) {
          raise JSON::ParserError, "unexpected token '<'" if url == WEBSITE
          "0x10"
        }) do
          assert_equal "0x10", client.call("eth_blockNumber")
          assert_equal "0x10", client.call("eth_blockNumber")
        end
      end
    end

    hits = logged.grep(/BASE_RPC_URL must be a Base JSON-RPC endpoint/)
    assert_equal 1, hits.size
    assert_includes hits.first, WEBSITE
  end

  test "a fallback endpoint returning non-JSON does not blame BASE_RPC_URL" do
    client = BaseRpcClient.new(url: WEBSITE)
    logged = capture_errors do
      client.stub(:sleep, nil) do
        client.stub(:execute, ->(url, *) {
          raise JSON::ParserError, "html" unless url == WEBSITE
          "0x10"
        }) do
          client.call("eth_blockNumber")
        end
      end
    end

    assert_empty logged.grep(/BASE_RPC_URL/)
  end

  private

  def capture_errors
    messages = []
    Rails.logger.stub(:error, ->(msg = nil) { messages << msg.to_s }) { yield }
    messages
  end
end

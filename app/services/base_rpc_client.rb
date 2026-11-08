# frozen_string_literal: true

# Shared JSON-RPC client for Base network with:
# - Exponential backoff retry (3 attempts) per endpoint
# - Fallback to a secondary public RPC if the primary endpoint is down
#   (mainnet.base.org is a shared free Cloudflare-fronted node that
#   occasionally rate-limits/bot-challenges and returns HTML instead of JSON)
# - Configurable timeout
# - Sanitized logging (no addresses/amounts in logs)
#
# Usage:
#   client = BaseRpcClient.new
#   nonce  = client.call("eth_getTransactionCount", [sender, "pending"]).to_i(16)
#   client.call("eth_sendRawTransaction", ["0x#{raw_tx}"])
#
class BaseRpcClient
  MAX_RETRIES    = 3
  BASE_DELAY     = 1     # seconds
  REQUEST_TIMEOUT = 30   # seconds
  OPEN_TIMEOUT    = 10   # seconds

  FALLBACK_URLS = [
    "https://base-mainnet.public.blastapi.io"
  ].freeze

  class RpcError < StandardError; end

  def initialize(url: nil)
    primary = url || ENV["BASE_RPC_URL"].presence || "https://mainnet.base.org"
    @urls = ([ primary ] + FALLBACK_URLS).uniq
  end

  def call(method, params = [])
    last_error = nil

    @urls.each do |url|
      MAX_RETRIES.times do |attempt|
        begin
          return execute(url, method, params)
        rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError => e
          last_error = e
          delay = BASE_DELAY * (2 ** attempt) # 1s, 2s, 4s
          Rails.logger.warn "BaseRpcClient: #{method} via #{url} attempt #{attempt + 1} failed (#{e.class}), retrying in #{delay}s"
          sleep(delay) if attempt < MAX_RETRIES - 1
        rescue RpcError => e
          # RPC errors (invalid params, execution reverted) should not be retried
          raise e
        end
      end
      Rails.logger.warn "BaseRpcClient: #{method} exhausted retries on #{url}, falling back to next endpoint"
    end

    raise RpcError, "BaseRpcClient: #{method} failed on all #{@urls.size} endpoint(s): #{last_error&.message}"
  end

  private

  def execute(url, method, params)
    conn = Faraday.new(url: url) do |f|
      f.options.timeout = REQUEST_TIMEOUT
      f.options.open_timeout = OPEN_TIMEOUT
      f.adapter Faraday.default_adapter
    end

    resp = conn.post do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
    end

    body = JSON.parse(resp.body)
    raise RpcError, "RPC error (#{method}): #{body['error']}" if body["error"]
    body["result"]
  end
end

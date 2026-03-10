# frozen_string_literal: true

# Redis-based nonce lock for treasury on-chain transactions.
# Prevents two Sidekiq workers from grabbing the same nonce simultaneously.
#
# Usage:
#   TreasuryNonceLock.with_nonce(rpc_url, sender_address) do |nonce|
#     # build, sign, and broadcast tx using this nonce
#   end
#
class TreasuryNonceLock
  LOCK_KEY     = "treasury:nonce_lock"
  LOCK_TIMEOUT = 60  # seconds — max time a worker can hold the lock
  RETRY_DELAY  = 0.5 # seconds between lock attempts
  MAX_RETRIES  = 30  # 30 * 0.5 = 15 seconds max wait

  class LockTimeout < StandardError; end

  def self.with_nonce(rpc_url, sender_address)
    redis = redis_connection
    acquired = false
    retries = 0

    # Acquire lock with NX + EX (atomic set-if-not-exists with expiry)
    while retries < MAX_RETRIES
      acquired = redis.set(LOCK_KEY, Process.pid.to_s, nx: true, ex: LOCK_TIMEOUT)
      break if acquired
      retries += 1
      sleep(RETRY_DELAY)
    end

    raise LockTimeout, "Could not acquire treasury nonce lock after #{MAX_RETRIES} attempts" unless acquired

    begin
      # Fetch nonce while holding the lock (uses BaseRpcClient with retry)
      client = BaseRpcClient.new(url: rpc_url)
      result = client.call("eth_getTransactionCount", [sender_address, "pending"])
      nonce  = result.to_i(16)

      yield nonce
    ensure
      redis.del(LOCK_KEY)
    end
  end

  def self.redis_connection
    @redis ||= begin
      url = ENV.fetch("REDIS_URL", "redis://localhost:6379/1")
      Redis.new(url: url)
    end
  end
end

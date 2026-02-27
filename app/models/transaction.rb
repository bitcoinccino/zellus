class Transaction < ApplicationRecord
  belongs_to :user
  enum :status,           { pending: 0, paid: 1, crypto_sent: 2, completed: 3, failed: 4, payout_failed: 5 }
  enum :transaction_type, { buy: "buy", sell: "sell", loan_request: "loan_request"  }
  enum :crypto_currency,  { usdc: "usdc", eth: "eth", wbtc: "wbtc" }

  FRIENDLY_ERRORS = {
    /exceeds balance/i              => "Our treasury wallet has insufficient funds. Please contact support.",
    /insufficient funds/i           => "Our treasury wallet has insufficient ETH for gas fees. Please contact support.",
    /nonce too low/i                => "Transaction conflict detected. Please try again.",
    /replacement transaction/i      => "A duplicate transaction was detected. Please contact support.",
    /invalid address/i              => "The recipient wallet address is invalid.",
    /gas required exceeds allowance/i => "Gas estimation failed. The transaction may be invalid.",
    /execution reverted/i           => "The transfer was rejected by the blockchain. Please contact support.",
    /TREASURY_PRIVATE_KEY not set/i => "Server configuration error. Please contact support.",
    /RPC returned no tx hash/i      => "The blockchain did not confirm the transaction. Please contact support.",
    /connection refused|timeout|ECONNREFUSED/i => "Could not reach the blockchain network. Please try again later.",
    /partner is blocked/i           => "Payment gateway error. Please contact support.",
    /MonCash connection failed/i    => "Payment gateway unavailable. Please try again later.",
    /MonCash customer check failed|MonCash payout failed|No short code for user account/i => "We received your USDC deposit, but the HTG payout could not be completed yet. Support will retry or assist you.",
  }

  def friendly_failure_reason
    return nil unless failure_reason.present?
    match = FRIENDLY_ERRORS.find { |pattern, _| failure_reason.match?(pattern) }
    match ? match[1] : "An unexpected error occurred. Please contact support."
  end
end

class FeeService
  # ── Transfer fees ──
  WALLET_FEE_RATE  = BigDecimal("0")     # 0% wallet-to-wallet (free P2P)
  MONCASH_FEE_RATE = BigDecimal("0.02")  # 2% for non-user payouts

  # ── Withdrawal fees ──
  INSTANT_FEE_RATE = BigDecimal("0.015") # 1.5%
  INSTANT_FEE_MIN  = BigDecimal("25")    # 25 HTG minimum
  INSTANT_FEE_MAX  = BigDecimal("2500")  # 2,500 HTG maximum

  STANDARD_FEE_RATE = BigDecimal("0.01") # 1%
  STANDARD_FEE_MIN  = BigDecimal("15")   # 15 HTG minimum

  BANK_WITHDRAW_FEE_RATE = BigDecimal("0.01") # 1%
  BANK_WITHDRAW_FEE_MIN  = BigDecimal("25")   # 25 HTG minimum

  # ── Crypto / conversion fee tiers (by HTG equivalent) ──
  CRYPTO_TIERS = [
    { max: 5_000,            rate: BigDecimal("0.0225") }, # 2.25%
    { max: 75_000,           rate: BigDecimal("0.0175") }, # 1.75%
    { max: Float::INFINITY,  rate: BigDecimal("0.015")  }  # 1.50%
  ].freeze

  # ── Transfer fee ──

  def self.transfer_fee_rate(transfer)
    return WALLET_FEE_RATE if transfer.payout_method == "wallet"
    MONCASH_FEE_RATE
  end

  # ── Withdrawal fees ──

  def self.instant_fee(amount)
    (amount.to_d * INSTANT_FEE_RATE).clamp(INSTANT_FEE_MIN, INSTANT_FEE_MAX).round(2)
  end

  def self.standard_fee(amount)
    [amount.to_d * STANDARD_FEE_RATE, STANDARD_FEE_MIN].max.round(2)
  end

  def self.bank_withdraw_fee(amount)
    [amount.to_d * BANK_WITHDRAW_FEE_RATE, BANK_WITHDRAW_FEE_MIN].max.round(2)
  end

  # ── Crypto / conversion fees ──

  def self.crypto_fee_rate(htg_amount)
    CRYPTO_TIERS.find { |t| htg_amount.to_d <= t[:max] }[:rate]
  end

  def self.crypto_fee(htg_amount)
    (htg_amount.to_d * crypto_fee_rate(htg_amount)).round(2)
  end

  # ── Display helpers ──

  def self.crypto_fee_percent(htg_amount)
    (crypto_fee_rate(htg_amount) * 100).to_f
  end

  def self.instant_fee_description
    "#{(INSTANT_FEE_RATE * 100).to_f}% (min #{INSTANT_FEE_MIN.to_i} HTG, maks #{INSTANT_FEE_MAX.to_i} HTG)"
  end

  def self.standard_fee_description
    "#{(STANDARD_FEE_RATE * 100).to_f}% (min #{STANDARD_FEE_MIN.to_i} HTG)"
  end

  def self.bank_fee_description
    "#{(BANK_WITHDRAW_FEE_RATE * 100).to_f}% (min #{BANK_WITHDRAW_FEE_MIN.to_i} HTG)"
  end
end

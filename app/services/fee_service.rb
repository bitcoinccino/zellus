class FeeService
  # ── Transfer fees ──
  WALLET_FEE_RATE  = BigDecimal("0")     # 0% wallet-to-wallet (free P2P)
  MONCASH_FEE_RATE = BigDecimal("0.02")  # 2% for non-user payouts

  # ── Withdrawal fees (flat 2% for all MonCash withdrawals) ──
  INSTANT_FEE_RATE = BigDecimal("0.02")  # 2%
  INSTANT_FEE_MIN  = BigDecimal("25")    # 25 HTG minimum
  INSTANT_FEE_MAX  = BigDecimal("2500")  # 2,500 HTG maximum

  STANDARD_FEE_RATE = BigDecimal("0.02") # 2% (same as instant — all withdrawals are instant)
  STANDARD_FEE_MIN  = BigDecimal("25")   # 25 HTG minimum

  BANK_WITHDRAW_FEE_RATE = BigDecimal("0.01") # 1%
  BANK_WITHDRAW_FEE_MIN  = BigDecimal("25")   # 25 HTG minimum

  # ── Remittance fees (UMA inbound) ──
  REMITTANCE_FEE_RATE = BigDecimal("0.015")  # 1.5%
  REMITTANCE_FEE_MIN  = BigDecimal("15")     # 15 HTG minimum

  # ── Crypto / conversion fee (flat 2%) ──
  CRYPTO_FEE_RATE = BigDecimal("0.02") # 2%

  # ── Transfer fee ──

  def self.transfer_fee_rate(transfer)
    return WALLET_FEE_RATE if transfer.payout_method == "wallet"
    return WALLET_FEE_RATE if transfer.respond_to?(:usd_wallet_transfer?) && transfer.usd_wallet_transfer?
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

  def self.remittance_fee(htg_amount)
    [htg_amount.to_d * REMITTANCE_FEE_RATE, REMITTANCE_FEE_MIN].max.round(2)
  end

  # ── Crypto / conversion fees ──

  def self.crypto_fee_rate(_htg_amount = nil)
    CRYPTO_FEE_RATE
  end

  def self.crypto_fee(htg_amount)
    (htg_amount.to_d * CRYPTO_FEE_RATE).round(2)
  end

  # ── Display helpers ──

  def self.crypto_fee_percent(_htg_amount = nil)
    (CRYPTO_FEE_RATE * 100).to_f
  end

  def self.instant_fee_description
    "#{(INSTANT_FEE_RATE * 100).to_f}% (min #{INSTANT_FEE_MIN.to_i} HTG, maks #{INSTANT_FEE_MAX.to_i} HTG)"
  end

  def self.standard_fee_description
    "#{(STANDARD_FEE_RATE * 100).to_f}% (min #{STANDARD_FEE_MIN.to_i} HTG)"
  end

  def self.withdraw_fee_description
    "#{(INSTANT_FEE_RATE * 100).to_f}%"
  end

  def self.bank_fee_description
    "#{(BANK_WITHDRAW_FEE_RATE * 100).to_f}% (min #{BANK_WITHDRAW_FEE_MIN.to_i} HTG)"
  end
end

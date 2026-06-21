class FeeService
  # ── Transfer fees ──
  WALLET_FEE_RATE  = BigDecimal("0")     # 0% wallet-to-wallet (free P2P)
  MONCASH_FEE_RATE = BigDecimal("0.02")  # 2% for non-user payouts

  # ── Withdrawal fee — flat 2% ────────────────────────────────────────────
  # Flat, not a "hump", on purpose. Withdrawals can be split into unlimited
  # transactions for free, so any schedule whose cheapest bracket sits at the
  # bottom is defeated by chunking down into it — a marginal hump only ever
  # taxes users naive enough to withdraw in one go. Only a flat or decreasing
  # schedule resists splitting, and a decreasing one re-introduces the
  # regressive small-user penalty. Flat 2% earns the same from honest users,
  # cannot be gamed, and keeps the 25 → 10 HTG floor fix.
  #
  # Kept as a single-tier WITHDRAW_TIERS (not a bare rate) so a split-safe
  # decreasing schedule — e.g. 2.0% up to 15k, 1.5% above — can be dropped in
  # later with no code change to the calculator.
  WITHDRAW_TIERS = [
    { upto: nil, rate: BigDecimal("0.02") }
  ].freeze
  WITHDRAW_FLOOR = BigDecimal("10")  # 10 HTG minimum, no maximum

  # ── Bank withdrawal fee (flat) ──
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

  # ── Marginal (tax-bracket) fee calculator ───────────────────────────────
  # Walks `tiers` low-to-high, charges each bracket's rate on the portion of
  # `amount` within it, sums the slices, then applies `floor` as a minimum.
  # Public so it can be unit-tested and reused for other tiered schedules.
  def self.marginal_fee(amount, tiers, floor: BigDecimal("0"))
    amt = amount.to_d
    return BigDecimal("0") if amt <= 0

    fee   = BigDecimal("0")
    lower = BigDecimal("0")

    tiers.each do |tier|
      ceiling   = tier[:upto]
      slice_top = ceiling.nil? ? amt : [ amt, ceiling ].min
      slice     = slice_top - lower
      break if slice <= 0

      fee  += slice * tier[:rate]
      lower = slice_top
      break if ceiling.nil? || amt <= ceiling
    end

    [ fee, floor ].max.round(2)
  end

  # ── Withdrawal fees ─────────────────────────────────────────────────────
  # All MonCash withdrawals are instant and share one tiered schedule.
  # instant_fee / standard_fee are kept as names because existing callers
  # (WalletService.calculate_instant_fee / calculate_standard_fee) use them.
  def self.withdraw_fee(amount)
    marginal_fee(amount, WITHDRAW_TIERS, floor: WITHDRAW_FLOOR)
  end

  def self.instant_fee(amount)
    withdraw_fee(amount)
  end

  def self.standard_fee(amount)
    withdraw_fee(amount)
  end

  def self.bank_withdraw_fee(amount)
    [ amount.to_d * BANK_WITHDRAW_FEE_RATE, BANK_WITHDRAW_FEE_MIN ].max.round(2)
  end

  def self.remittance_fee(htg_amount)
    [ htg_amount.to_d * REMITTANCE_FEE_RATE, REMITTANCE_FEE_MIN ].max.round(2)
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

  def self.withdraw_fee_description
    pcts = WITHDRAW_TIERS.map { |t| (t[:rate] * 100).to_f }
    rate_str = pcts.uniq.size == 1 ? "#{pcts.first}%" : "#{pcts.min}%–#{pcts.max}% selon montan"
    "#{rate_str} (min #{WITHDRAW_FLOOR.to_i} HTG)"
  end

  def self.bank_fee_description
    "#{(BANK_WITHDRAW_FEE_RATE * 100).to_f}% (min #{BANK_WITHDRAW_FEE_MIN.to_i} HTG)"
  end
end

class WalletLimitService
  TIERS = {
    unverified: {
      daily_deposit_usd: BigDecimal("500"),
      daily_swap_usd:    BigDecimal("250"),
      max_balance_usd:   BigDecimal("1000")
    },
    verified: {
      daily_deposit_usd: BigDecimal("2500"),
      daily_swap_usd:    BigDecimal("1000"),
      max_balance_usd:   BigDecimal("10000")
    }
  }.freeze

  def initialize(user)
    @user   = user
    @wallet = user.wallet
    @tier   = user.bonid_verified? ? :verified : :unverified
  end

  def limits
    TIERS[@tier]
  end

  # ── Daily swap: sum of today's USD→HTG conversion_out entries ──
  def daily_swap_used
    @wallet.wallet_ledger_entries
      .where(entry_type: "conversion_out", asset: "usdc")
      .where("created_at >= ?", haiti_today)
      .sum(:amount)
  end

  def daily_swap_remaining
    [limits[:daily_swap_usd] - daily_swap_used, BigDecimal("0")].max
  end

  def swap_allowed?(usd_amount)
    daily_swap_used + usd_amount.to_d <= limits[:daily_swap_usd]
  end

  # ── Max wallet balance ──
  def balance_would_exceed?(additional_usd)
    (@wallet.usdc_balance + additional_usd.to_d) > limits[:max_balance_usd]
  end

  def max_balance
    limits[:max_balance_usd]
  end

  def tier_name
    @tier == :verified ? "BonID Verifye" : "Pa Verifye"
  end

  private

  def haiti_today
    Time.current.in_time_zone("America/Port-au-Prince").beginning_of_day
  end
end

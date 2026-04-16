class WalletLimitService
  # Per-user daily limits (multiplied by VERIFIED_LIMIT_MULTIPLIER for BonID-verified)
  def self.config
    {
      buy_min_htg:              env_d("BUY_MIN_HTG", 500),
      buy_max_htg:              env_d("BUY_MAX_HTG", 65_000),
      buy_daily_user_max_usd:   env_d("BUY_DAILY_USER_MAX_USD", 500),
      buy_daily_platform_max:   env_d("BUY_DAILY_PLATFORM_MAX_USD", 2_000),

      convert_min_usd:          env_d("CONVERT_MIN_USD", 1),
      convert_max_usd:          env_d("CONVERT_MAX_USD", 500),
      convert_daily_user_usd:   env_d("CONVERT_DAILY_USER_MAX_USD", 250),
      convert_daily_user_htg:   env_d("CONVERT_DAILY_USER_MAX_HTG", 25_000),

      withdraw_min_htg:         env_d("WITHDRAW_MIN_HTG", 500),
      withdraw_max_htg:         env_d("WITHDRAW_MAX_HTG", 50_000),
      withdraw_daily_user_htg:  env_d("WITHDRAW_DAILY_USER_MAX_HTG", 50_000),
      withdraw_daily_platform:  env_d("WITHDRAW_DAILY_PLATFORM_MAX_HTG", 200_000),

      usdc_withdraw_max:        env_d("USDC_WITHDRAW_MAX", 500),
      usdc_daily_user_max:      env_d("USDC_DAILY_USER_MAX", 1_000),
      usdc_daily_platform_max:  env_d("USDC_DAILY_PLATFORM_MAX", 2_000),

      verified_multiplier:      env_d("VERIFIED_LIMIT_MULTIPLIER", 2),

      platform_usdc_reserve_min: env_d("PLATFORM_USDC_RESERVE_MIN", 2_000),
      platform_htg_reserve_min:  env_d("PLATFORM_HTG_RESERVE_MIN", 260_000),
      reserve_alert_pct:         env_d("PLATFORM_RESERVE_ALERT_THRESHOLD_PCT", 25)
    }
  end

  def self.env_d(key, default)
    BigDecimal(ENV[key].presence || default.to_s)
  end

  # Legacy TIERS — kept for any callers still using it
  TIERS = {
    unverified: { daily_deposit_usd: BigDecimal("500"), daily_swap_usd: BigDecimal("250"), max_balance_usd: BigDecimal("1000") },
    verified:   { daily_deposit_usd: BigDecimal("2500"), daily_swap_usd: BigDecimal("1000"), max_balance_usd: BigDecimal("10000") }
  }.freeze

  def initialize(user)
    @user   = user
    @wallet = user.wallet
    @cfg    = self.class.config
    @mult   = user.bonid_verified? ? @cfg[:verified_multiplier] : BigDecimal("1")
  end

  # ── User-tier limits (with verified multiplier applied) ──
  def buy_max_htg;            @cfg[:buy_max_htg] * @mult; end
  def buy_daily_max_usd;      @cfg[:buy_daily_user_max_usd] * @mult; end
  def convert_max_usd;        @cfg[:convert_max_usd] * @mult; end
  def convert_daily_max_usd;  @cfg[:convert_daily_user_usd] * @mult; end
  def convert_daily_max_htg;  @cfg[:convert_daily_user_htg] * @mult; end
  def withdraw_max_htg;       @cfg[:withdraw_max_htg] * @mult; end
  def withdraw_daily_max_htg; @cfg[:withdraw_daily_user_htg] * @mult; end
  def usdc_withdraw_max;      @cfg[:usdc_withdraw_max] * @mult; end
  def usdc_daily_max;         @cfg[:usdc_daily_user_max] * @mult; end

  # ── Today's usage (per user, per asset) ──
  def buy_used_today_usd
    @user.transactions.where(transaction_type: "buy", created_at: today_range)
      .where(status: %w[completed pending sent funded]).sum(:crypto_amount).to_d
  end

  def convert_usd_used_today
    @wallet.wallet_ledger_entries.where(entry_type: "conversion_out", asset: "usd", created_at: today_range).sum(:amount).to_d
  end

  def convert_htg_used_today
    @wallet.wallet_ledger_entries.where(entry_type: "conversion_out", asset: "htg", created_at: today_range).sum(:amount).to_d
  end

  def withdraw_htg_used_today
    @wallet.wallet_ledger_entries.where(entry_type: "withdrawal", asset: "htg", created_at: today_range).sum(:amount).to_d
  end

  def withdraw_usdc_used_today
    @wallet.wallet_ledger_entries.where(entry_type: "withdrawal", asset: "usd", created_at: today_range).sum(:amount).to_d
  end

  # ── Allow checks (returns [allowed?, reason] tuple) ──
  def allow_buy?(usd_amount)
    return [false, "Sistèm pa disponib pou kounye a (rezèv ba)"] if self.class.platform_paused?(:usdc)
    return [false, "Limit jounalye depase"] if buy_used_today_usd + usd_amount.to_d > buy_daily_max_usd
    [true, nil]
  end

  def allow_convert_to_usd?(usd_amount)
    return [false, "Sistèm pa disponib pou kounye a (rezèv ba)"] if self.class.platform_paused?(:usdc)
    return [false, "Montan twòp gran"] if usd_amount.to_d > convert_max_usd
    return [false, "Limit jounalye depase"] if convert_usd_used_today + usd_amount.to_d > convert_daily_max_usd
    [true, nil]
  end

  def allow_convert_to_htg?(htg_amount)
    return [false, "Sistèm pa disponib pou kounye a (rezèv ba)"] if self.class.platform_paused?(:htg)
    return [false, "Limit jounalye depase"] if convert_htg_used_today + htg_amount.to_d > convert_daily_max_htg
    [true, nil]
  end

  def allow_withdraw_htg?(htg_amount)
    return [false, "Sistèm pa disponib pou kounye a (rezèv ba)"] if self.class.platform_paused?(:htg)
    return [false, "Montan twòp gran (max #{withdraw_max_htg.to_i} HTG)"] if htg_amount.to_d > withdraw_max_htg
    return [false, "Limit jounalye depase"] if withdraw_htg_used_today + htg_amount.to_d > withdraw_daily_max_htg
    [true, nil]
  end

  def allow_withdraw_usdc?(usd_amount)
    return [false, "Sistèm pa disponib pou kounye a (rezèv ba)"] if self.class.platform_paused?(:usdc)
    return [false, "Montan twòp gran (max $#{usdc_withdraw_max.to_i})"] if usd_amount.to_d > usdc_withdraw_max
    return [false, "Limit jounalye depase"] if withdraw_usdc_used_today + usd_amount.to_d > usdc_daily_max
    [true, nil]
  end

  # ── Platform-level reserves and circuit breaker ──
  def self.platform_usdc_reserve
    User.joins(:wallet).where(email: ENV["ADMIN_EMAIL"].to_s.strip).first&.wallet&.usd_balance.to_d
  end

  def self.platform_htg_reserve
    User.joins(:wallet).where(email: ENV["ADMIN_EMAIL"].to_s.strip).first&.wallet&.htg_balance.to_d
  end

  def self.platform_paused?(asset)
    cfg = config
    case asset
    when :usdc then platform_usdc_reserve < cfg[:platform_usdc_reserve_min]
    when :htg  then platform_htg_reserve < cfg[:platform_htg_reserve_min]
    else false
    end
  end

  def self.platform_health
    cfg = config
    {
      usdc: {
        reserve: platform_usdc_reserve,
        minimum: cfg[:platform_usdc_reserve_min],
        paused:  platform_paused?(:usdc),
        alert:   platform_usdc_reserve < (cfg[:platform_usdc_reserve_min] * (cfg[:reserve_alert_pct] / 100 + 1))
      },
      htg: {
        reserve: platform_htg_reserve,
        minimum: cfg[:platform_htg_reserve_min],
        paused:  platform_paused?(:htg),
        alert:   platform_htg_reserve < (cfg[:platform_htg_reserve_min] * (cfg[:reserve_alert_pct] / 100 + 1))
      }
    }
  end

  # ── Legacy compatibility ──
  def limits
    TIERS[@user.bonid_verified? ? :verified : :unverified]
  end

  def daily_swap_used; convert_usd_used_today; end
  def daily_swap_remaining; [convert_daily_max_usd - daily_swap_used, BigDecimal("0")].max; end
  def swap_allowed?(usd_amount); allow_convert_to_usd?(usd_amount).first; end
  def balance_would_exceed?(additional_usd); (@wallet.usd_balance + additional_usd.to_d) > limits[:max_balance_usd]; end
  def max_balance; limits[:max_balance_usd]; end
  def tier_name; @user.bonid_verified? ? "BonID Verifye" : "Pa Verifye"; end

  private

  def today_range
    haiti_today = Time.current.in_time_zone("America/Port-au-Prince").beginning_of_day
    haiti_today..Float::INFINITY
  end
end

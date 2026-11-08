module WalletsHelper
  # One source of truth for the wallet page's money figures.
  #
  # Every asset card shows its balance and its cross-currency equivalent
  # rounded to cents (half-up), and the hero totals are the SUM of those
  # displayed cents. That way "Valè Total" always equals what the cards add up
  # to, and a 1.00738 USD balance can't show 136.86 HTG on its card but
  # 136.85 (or 136.50) in the total.
  #
  # Mirrored in JS by ZellusMoney.figures (layouts/application.html.erb);
  # keep the two in step.
  #
  # Returns integer cents.
  def wallet_figures(htg:, usd:, wbtc: 0, eth: 0, usd_htg:, btc_usd: 0, eth_usd: 0)
    d = ->(v) { BigDecimal(v.to_s) }
    cents = ->(v) { (v * 100).round(0, BigDecimal::ROUND_HALF_UP).to_i }

    rate     = d.(usd_htg)
    htg_c    = cents.(d.(htg))
    usd_c    = cents.(d.(usd))
    wbtc_usd = d.(wbtc) * d.(btc_usd)
    eth_usd  = d.(eth) * d.(eth_usd)

    htg_in_usd_c  = rate.zero? ? 0 : cents.(d.(htg_c) / 100 / rate)
    usd_in_htg_c  = cents.(d.(usd_c) / 100 * rate)
    wbtc_usd_c    = cents.(wbtc_usd)
    eth_usd_c     = cents.(eth_usd)
    wbtc_htg_c    = cents.(wbtc_usd * rate)
    eth_htg_c     = cents.(eth_usd * rate)

    {
      htg: htg_c, usd: usd_c,
      htg_in_usd: htg_in_usd_c, usd_in_htg: usd_in_htg_c,
      wbtc_usd: wbtc_usd_c, eth_usd: eth_usd_c,
      total_htg: htg_c + usd_in_htg_c + wbtc_htg_c + eth_htg_c,
      total_usd: usd_c + htg_in_usd_c + wbtc_usd_c + eth_usd_c
    }
  end

  # 13686 → ["136", "86"]; whole part gets thousands separators.
  def cents_parts(cents)
    [number_with_delimiter(cents / 100), format("%02d", cents % 100)]
  end
end

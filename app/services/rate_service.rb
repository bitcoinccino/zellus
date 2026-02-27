class RateService
  DEFAULT_USD_HTG_FALLBACK = 135.50
  DEFAULT_BTC_USD_FALLBACK = 95_000.0
  DEFAULT_ETH_USD_FALLBACK = 3_500.0
  DEFAULT_CACHE_TTL_SECONDS = 300

  class << self
    FETCHED_AT_CACHE_KEY = "rates/usd_htg_fetched_at".freeze

    # ── USD/HTG rates (for USDC) ─────────────────────────────────────
    def buy_rate
      apply_margin(usd_htg_rate, buy_margin_percent, direction: :add)
    end

    def sell_rate
      apply_margin(usd_htg_rate, sell_margin_percent, direction: :subtract)
    end

    def usd_htg_rate
      Rails.cache.fetch("rates/usd_htg", expires_in: cache_ttl_seconds.seconds) do
        rate = fetch_usd_htg_rate || fallback_rate
        write_fetched_timestamp
        rate
      end
    rescue => e
      Rails.logger.error "RateService cache/fetch error: #{e.message}"
      fallback_rate
    end

    # ── BTC/HTG rates (for WBTC) ─────────────────────────────────────
    def btc_usd_rate
      Rails.cache.fetch("rates/btc_usd", expires_in: cache_ttl_seconds.seconds) do
        fetch_crypto_usd_rate("bitcoin") || btc_usd_fallback
      end
    rescue => e
      Rails.logger.error "RateService BTC/USD cache error: #{e.message}"
      btc_usd_fallback
    end

    def wbtc_htg_buy_rate
      (btc_usd_rate * buy_rate).round(2)
    end

    def wbtc_htg_sell_rate
      (btc_usd_rate * sell_rate).round(2)
    end

    # ── ETH/HTG rates ────────────────────────────────────────────────
    def eth_usd_rate
      Rails.cache.fetch("rates/eth_usd", expires_in: cache_ttl_seconds.seconds) do
        fetch_crypto_usd_rate("ethereum") || eth_usd_fallback
      end
    rescue => e
      Rails.logger.error "RateService ETH/USD cache error: #{e.message}"
      eth_usd_fallback
    end

    def eth_htg_buy_rate
      (eth_usd_rate * buy_rate).round(2)
    end

    def eth_htg_sell_rate
      (eth_usd_rate * sell_rate).round(2)
    end

    # ── Timestamp ────────────────────────────────────────────────────
    def usd_htg_rate_updated_at
      value = Rails.cache.read(FETCHED_AT_CACHE_KEY)
      case value
      when Time then value
      when String then Time.zone.parse(value) rescue nil
      else nil
      end
    rescue => e
      Rails.logger.error "RateService cache timestamp read error: #{e.message}"
      nil
    end

    private

    # ── FX rate fetch ────────────────────────────────────────────────
    def fetch_usd_htg_rate
      conn = Faraday.new(url: rate_api_base_url)
      response = conn.get("/convert") do |req|
        req.params["from"] = "USD"
        req.params["to"]   = "HTG"
        req.params["amount"] = 1
        access_key = ENV["FX_API_KEY"].to_s.strip
        req.params["access_key"] = access_key if access_key.present?
      end

      return nil unless response.success?

      data = JSON.parse(response.body) rescue {}
      rate = data["result"] || data.dig("info", "rate") || data.dig("rates", "HTG")
      rate = rate.to_f
      return nil if rate <= 0

      Rails.logger.info "RateService USD/HTG fetched: #{rate}"
      rate.round(4)
    rescue => e
      Rails.logger.error "RateService fetch failed: #{e.message}"
      nil
    end

    # ── Crypto/USD rate fetch (CoinGecko) ────────────────────────────
    def fetch_crypto_usd_rate(coin_id)
      base_url = ENV["CRYPTO_RATE_API_URL"].presence || "https://api.coingecko.com"
      conn = Faraday.new(url: base_url)
      response = conn.get("/api/v3/simple/price") do |req|
        req.params["ids"] = coin_id
        req.params["vs_currencies"] = "usd"
      end

      return nil unless response.success?

      data = JSON.parse(response.body) rescue {}
      rate = data.dig(coin_id, "usd").to_f
      return nil if rate <= 0

      Rails.logger.info "RateService #{coin_id}/USD fetched: #{rate}"
      rate.round(2)
    rescue => e
      Rails.logger.error "RateService #{coin_id}/USD fetch failed: #{e.message}"
      nil
    end

    def rate_api_base_url
      ENV["FX_API_BASE_URL"].presence || "https://api.exchangerate.host"
    end

    def fallback_rate
      ENV.fetch("USD_HTG_FALLBACK_RATE", DEFAULT_USD_HTG_FALLBACK.to_s).to_f
    end

    def btc_usd_fallback
      ENV.fetch("BTC_USD_FALLBACK_RATE", DEFAULT_BTC_USD_FALLBACK.to_s).to_f
    end

    def eth_usd_fallback
      ENV.fetch("ETH_USD_FALLBACK_RATE", DEFAULT_ETH_USD_FALLBACK.to_s).to_f
    end

    def cache_ttl_seconds
      ENV.fetch("USD_HTG_RATE_CACHE_TTL_SECONDS", DEFAULT_CACHE_TTL_SECONDS.to_s).to_i.clamp(30, 3600)
    end

    def buy_margin_percent
      ENV.fetch("USD_HTG_BUY_MARGIN_PERCENT", "0").to_f
    end

    def sell_margin_percent
      ENV.fetch("USD_HTG_SELL_MARGIN_PERCENT", "0").to_f
    end

    def apply_margin(base_rate, margin_percent, direction:)
      multiplier = 1.0 + (margin_percent / 100.0)
      rate = case direction
      when :add then base_rate * multiplier
      when :subtract then base_rate * (1.0 - (margin_percent / 100.0))
      else base_rate
      end
      rate.round(2)
    end

    def write_fetched_timestamp
      timestamp = Time.current
      Rails.cache.write(FETCHED_AT_CACHE_KEY, timestamp, expires_in: cache_ttl_seconds.seconds)
    rescue => e
      Rails.logger.error "RateService cache timestamp write error: #{e.message}"
    end
  end
end

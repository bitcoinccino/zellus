class RateService
  DEFAULT_USD_HTG_FALLBACK = 135.50
  DEFAULT_BTC_USD_FALLBACK = 95_000.0
  DEFAULT_ETH_USD_FALLBACK = 3_500.0
  DEFAULT_CACHE_TTL_SECONDS = 300

  # Sanity band for USD→HTG. Anything outside this range is almost certainly
  # an API glitch or stale/corrupted cache entry, not a real market move.
  # HTG has hovered around 100-170 per USD for years. Reject and use fallback.
  MIN_REASONABLE_USD_HTG = 50.0
  MAX_REASONABLE_USD_HTG = 300.0

  # Approximate fallback prices (USD) for tokenized stocks
  STOCK_FALLBACKS = {
    "tslax"  => 395.0,
    "nvdax"  => 190.0,
    "aaplx"  => 265.0,
    "coinx"  => 180.0,
    "googlx" => 310.0
  }.freeze

  STOCK_CMC_SLUGS = {
    "tslax"  => "tesla-tokenized-stock-xstock",
    "nvdax"  => "nvidia-tokenized-stock-xstock",
    "aaplx"  => "apple-tokenized-stock-xstock",
    "coinx"  => "coinbase-tokenized-stock-xstock",
    "googlx" => "alphabet-tokenized-stock-xstock"
  }.freeze

  # Unified CMC slugs for all assets (crypto + stocks)
  CMC_SLUGS = {
    "usd"    => "usd-coin",
    "btc"    => "bitcoin",
    "eth"    => "ethereum",
    "tslax"  => "tesla-tokenized-stock-xstock",
    "nvdax"  => "nvidia-tokenized-stock-xstock",
    "aaplx"  => "apple-tokenized-stock-xstock",
    "coinx"  => "coinbase-tokenized-stock-xstock",
    "googlx" => "alphabet-tokenized-stock-xstock"
  }.freeze

  class << self
    FETCHED_AT_CACHE_KEY = "rates/usd_htg_fetched_at".freeze

    # ── USD/HTG rates ─────────────────────────────────────
    def buy_rate
      apply_margin(usd_htg_rate, buy_margin_percent, direction: :add)
    end

    def sell_rate
      apply_margin(usd_htg_rate, sell_margin_percent, direction: :subtract)
    end

    def usd_htg_rate
      raw = Rails.cache.fetch("rates/usd_htg", expires_in: cache_ttl_seconds.seconds) do
        rate = fetch_usd_htg_rate || fallback_rate
        write_fetched_timestamp
        rate
      end.to_f

      # Guard against poisoned cache entries / API glitches. HTG/USD has
      # hovered around 100-170 for years — anything outside the sanity band
      # is almost certainly a bad API response (e.g. 0.303 instead of 135.50)
      # that would render conversions like "4.49 USD ≈ 1.36 HTG".
      if raw.between?(MIN_REASONABLE_USD_HTG, MAX_REASONABLE_USD_HTG)
        raw
      else
        Rails.logger.error "RateService: USD/HTG out of sanity band (#{raw.inspect}) — using fallback #{fallback_rate}"
        Rails.cache.delete("rates/usd_htg") rescue nil
        fallback_rate
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

    # ── Stock token rates (xStocks on Base) ──────────────────────────
    def stock_usd_rate(ticker)
      ticker = ticker.to_s.downcase
      Rails.cache.fetch("rates/#{ticker}_usd", expires_in: 30.seconds) do
        fetch_stock_usd_rate(ticker) || STOCK_FALLBACKS.fetch(ticker, 0.0)
      end
    rescue => e
      Rails.logger.error "RateService #{ticker}/USD cache error: #{e.message}"
      STOCK_FALLBACKS.fetch(ticker, 0.0)
    end

    def stock_htg_buy_rate(ticker)
      (stock_usd_rate(ticker) * buy_rate).round(2)
    end

    def stock_htg_sell_rate(ticker)
      (stock_usd_rate(ticker) * sell_rate).round(2)
    end

    # Convenience methods for each stock
    %w[tslax nvdax aaplx coinx googlx].each do |t|
      define_method(:"#{t}_usd_rate") { stock_usd_rate(t) }
      define_method(:"#{t}_htg_buy_rate") { stock_htg_buy_rate(t) }
      define_method(:"#{t}_htg_sell_rate") { stock_htg_sell_rate(t) }
    end

    # ── Market Data (CoinMarketCap) ────────────────────────────────
    def market_data(key)
      key = key.to_s.downcase
      slug = CMC_SLUGS[key]
      return {} unless slug

      Rails.cache.fetch("market_data/#{key}", expires_in: 5.minutes) do
        fetch_cmc_market_data(slug)
      end
    rescue => e
      Rails.logger.error "RateService market_data(#{key}) error: #{e.message}"
      {}
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

      # Drop obviously bad values at the source so they never reach the cache.
      unless rate.between?(MIN_REASONABLE_USD_HTG, MAX_REASONABLE_USD_HTG)
        Rails.logger.error "RateService USD/HTG fetch returned out-of-band value #{rate} — ignoring"
        return nil
      end

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

    # ── Stock/USD rate fetch (CoinMarketCap) ──────────────────────────
    def fetch_stock_usd_rate(ticker)
      slug = STOCK_CMC_SLUGS[ticker]
      return nil unless slug

      api_key = ENV["COINMARKETCAP_API_KEY"].to_s.strip
      return nil if api_key.blank?

      conn = Faraday.new(url: "https://pro-api.coinmarketcap.com")
      response = conn.get("/v1/cryptocurrency/quotes/latest") do |req|
        req.params["slug"] = slug
        req.headers["X-CMC_PRO_API_KEY"] = api_key
        req.headers["Accept"] = "application/json"
      end

      return nil unless response.success?

      data = JSON.parse(response.body) rescue {}
      # CMC returns { data: { "<id>": { quote: { USD: { price: ... } } } } }
      coin_data = data.dig("data")&.values&.first
      price = coin_data&.dig("quote", "USD", "price").to_f
      return nil if price <= 0

      Rails.logger.info "RateService #{ticker}/USD fetched: #{price}"
      price.round(2)
    rescue => e
      Rails.logger.error "RateService #{ticker}/USD CMC fetch failed: #{e.message}"
      nil
    end

    # ── CMC market data fetch ──────────────────────────────────────
    def fetch_cmc_market_data(slug)
      api_key = ENV["COINMARKETCAP_API_KEY"].to_s.strip
      return {} if api_key.blank?

      conn = Faraday.new(url: "https://pro-api.coinmarketcap.com")
      response = conn.get("/v1/cryptocurrency/quotes/latest") do |req|
        req.params["slug"] = slug
        req.headers["X-CMC_PRO_API_KEY"] = api_key
        req.headers["Accept"] = "application/json"
      end

      return {} unless response.success?

      data = JSON.parse(response.body) rescue {}
      coin_data = data.dig("data")&.values&.first
      return {} unless coin_data

      quote = coin_data.dig("quote", "USD") || {}

      {
        market_cap:          quote["market_cap"].to_f,
        volume_24h:          quote["volume_24h"].to_f,
        percent_change_24h:  quote["percent_change_24h"].to_f.round(2),
        fdv:                 quote["fully_diluted_market_cap"].to_f,
        circulating_supply:  coin_data["circulating_supply"].to_f,
        total_supply:        coin_data["total_supply"].to_f,
        max_supply:          coin_data["max_supply"].to_f,
        symbol:              coin_data["symbol"].to_s,
        price:               quote["price"].to_f.round(2)
      }
    rescue => e
      Rails.logger.error "RateService CMC market_data fetch failed for #{slug}: #{e.message}"
      {}
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

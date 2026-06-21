require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class Bonid < OmniAuth::Strategies::OAuth2
      option :name, "bonid"

      option :client_options, {
        site:          ENV.fetch("BONID_BASE_URL", "http://localhost:3001").sub(%r{/api/v\d+\z}, ""),
        authorize_url: "/oauth/authorize",
        token_url:     "/oauth/token"
      }

      option :authorize_params, {
        scope: "openid profile email phone address health identity:verify crime:status"
      }

      # BonID manages its own session security via grant_token
      option :provider_ignores_state, true

      # Ensure redirect_uri uses the actual request host (important for ngrok/tunnels)
      # Ngrok terminates SSL, so the request arrives as HTTP — force HTTPS for ngrok hosts
      def callback_url
        url = full_host + callback_path
        if url.include?("ngrok") && url.start_with?("http://")
          url = url.sub("http://", "https://")
        end
        Rails.logger.warn "BonID callback_url: #{url}" if defined?(Rails)
        url
      end

      def request_phase
        Rails.logger.warn "═══ BonID OAuth REQUEST PHASE ═══" if defined?(Rails)
        Rails.logger.warn "  site:         #{options.client_options[:site]}" if defined?(Rails)
        Rails.logger.warn "  authorize_url: #{options.client_options[:authorize_url]}" if defined?(Rails)
        Rails.logger.warn "  token_url:     #{options.client_options[:token_url]}" if defined?(Rails)
        Rails.logger.warn "  callback_url:  #{callback_url}" if defined?(Rails)
        Rails.logger.warn "  client_id:     #{options.client_id[0..8]}..." if defined?(Rails)
        Rails.logger.warn "═══════════════════════════════════" if defined?(Rails)
        super
      end

      def callback_phase
        Rails.logger.warn "═══ BonID OAuth CALLBACK PHASE ═══" if defined?(Rails)
        Rails.logger.warn "  params: #{request.params.except('code').inspect}" if defined?(Rails)
        Rails.logger.warn "  code present: #{request.params['code'].present?}" if defined?(Rails)
        Rails.logger.warn "  error: #{request.params['error']}" if request.params["error"] && defined?(Rails)
        Rails.logger.warn "  error_description: #{request.params['error_description']}" if request.params["error_description"] && defined?(Rails)
        Rails.logger.warn "═══════════════════════════════════" if defined?(Rails)
        super
      end

      uid { raw_info["bonid"] }

      info do
        name_parts = (raw_info["name"] || "").split(/\s+/, 2)
        addr = raw_info["address"] || {}
        {
          bonid:      raw_info["bonid"],
          first_name: raw_info["first_name"] || name_parts[0],
          last_name:  raw_info["last_name"]  || name_parts[1],
          name:       raw_info["name"] || [ raw_info["first_name"], raw_info["last_name"] ].compact.join(" "),
          email:      raw_info["email"],
          phone:      raw_info["phone"],
          image:      raw_info["photo_url"],
          # ── Address (nested from BonID) ──
          street:     addr["street"],
          locality:   addr["locality"],       # ville/section
          commune:    addr["commune"],         # e.g. "Côtes-de-Fer"
          department: addr["department"],      # e.g. "Sud-Est"
          country:    addr["country"] || "HT",
          # ── Health (nested from BonID) ──
          blood_type: (raw_info["health"] || {})["blood_type"]
        }
      end

      extra do
        { raw_info: raw_info }
      end

      def raw_info
        @raw_info ||= begin
          Rails.logger.warn "BonID: Fetching userinfo with token: #{access_token.token[0..8]}..." if defined?(Rails)
          resp = access_token.get("/oauth/userinfo")
          Rails.logger.warn "BonID userinfo status: #{resp.status}, body: #{resp.body[0..500]}" if defined?(Rails)
          data = resp.parsed
          # Flatten nested identity hash if present
          identity = data["identity"] || {}
          identity.merge(data.except("identity"))
        end
      rescue => e
        Rails.logger.error "BonID userinfo FAILED: #{e.class}: #{e.message}" if defined?(Rails)
        {}
      end
    end
  end
end

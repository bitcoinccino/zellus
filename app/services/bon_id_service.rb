class BonIdService
  BASE_URLS = {
    "production"  => "https://api.bonid.ht/api/v1",
    "sandbox"     => "https://sandbox.bonid.ht/api/v1",
    "development" => "http://localhost:3000/api/v1"
  }.freeze

  def self.base_url
    raw = ENV.fetch("BONID_BASE_URL") { BASE_URLS[Rails.env] || BASE_URLS["sandbox"] }
    # Ensure the URL always ends with /api/v1
    raw.sub(%r{/?\z}, "").then { |u| u.match?(%r{/api/v\d+\z}) ? u : "#{u}/api/v1" }
  end

  def self.api_key
    ENV.fetch("BONID_API_KEY", "")
  end

  # Quick status check — returns { verified: true/false } or { error: "..." }
  def self.check_status(bonid)
    response = connection.get("identity/#{bonid}/status")

    if response.success?
      data = JSON.parse(response.body)
      { success: true, verified: data["verified"] == true, bonid: data["bonid"] }
    else
      handle_error(response)
    end
  rescue Faraday::Error => e
    Rails.logger.error "BonID status check failed: #{e.message}"
    { success: false, error: "Koneksyon ak BonID echwe. Tanpri eseye ankò." }
  end

  # Full identity lookup — returns identity details
  def self.lookup(bonid)
    response = connection.get("identity/#{bonid}")

    if response.success?
      data = JSON.parse(response.body)
      {
        success: true,
        verified: data["verified"] == true,
        bonid: data["bonid"],
        id_type: data["id_type"],
        identity: data["identity"]
      }
    else
      handle_error(response)
    end
  rescue Faraday::Error => e
    Rails.logger.error "BonID lookup failed: #{e.message}"
    { success: false, error: "Koneksyon ak BonID echwe. Tanpri eseye ankò." }
  end

  # ── Crime Status Check (dual auth: API key + OAuth token) ──
  # Used during OAuth login — requires both partner API key and user's OAuth token
  def self.check_crime_status(bonid, oauth_token = nil)
    conn = Faraday.new(url: "#{base_url}/") do |f|
      f.headers["X-Partner-Api-Key"] = api_key
      f.headers["Authorization"] = "Bearer #{oauth_token}" if oauth_token.present?
      f.headers["Accept"] = "application/json"
      f.options.timeout = 10
      f.options.open_timeout = 5
      f.adapter Faraday.default_adapter
    end

    response = conn.get("crime_status/#{bonid}")

    if response.success?
      data = JSON.parse(response.body)
      crime = data["crime_status"] || {}
      {
        success: true,
        has_criminal_record: crime["has_criminal_record"] == true,
        severity_label: crime["severity_label"],
        involvement_count: crime["involvement_count"],
        access_tier: data["access_tier"]
      }
    else
      handle_error(response)
    end
  rescue Faraday::Error => e
    Rails.logger.error "BonID crime status check failed: #{e.message}"
    { success: false, error: "Verifikasyon echwe. Tanpri eseye ankò." }
  rescue JSON::ParserError => e
    Rails.logger.error "BonID crime status parse error: #{e.message}"
    { success: false, error: "Repons BonID pa valid." }
  end

  # Verify a user: look up their BonID and persist the result
  def self.verify_user!(user, bonid)
    result = lookup(bonid)

    unless result[:success]
      return { success: false, error: result[:error] }
    end

    unless result[:verified]
      return { success: false, error: "BonID sa a pa verifye. Tanpri tcheke nimewo a epi eseye ankò." }
    end

    identity = result[:identity] || {}
    user.update!(
      bonid: result[:bonid],
      bonid_verified_at: Time.current,
      bonid_first_name: identity["first_name"],
      bonid_last_name: identity["last_name"],
      bonid_photo_url: identity["photo_url"]
    )

    { success: true, identity: identity }
  end

  # ══════════════════════════════════════════════════
  # Per-Transaction Consent API
  # ══════════════════════════════════════════════════

  CONSENT_THRESHOLD = BigDecimal(ENV.fetch("BONID_CONSENT_THRESHOLD", "50"))

  # Should this transfer require BonID consent?
  def self.consent_required?(transfer)
    return false unless transfer.user&.bonid.present?
    transfer.amount >= CONSENT_THRESHOLD
  end

  # Request consent for a transfer — returns consent_token + expiry
  def self.request_consent(transfer)
    user = transfer.user
    return { success: false, error: "Itilizatè pa gen BonID" } unless user&.bonid.present?

    reference_id = "ZEL-transfer-#{transfer.token}"
    receiver_label = transfer.receiver_cashtag.present? ? "$#{transfer.receiver_cashtag}" : (transfer.receiver_name.presence || transfer.receiver_phone)

    response = connection.post("transaction_consents") do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = {
        bonid: user.bonid,
        transaction_type: "p2p_transfer",
        scopes: ["identity"],
        amount: transfer.amount.to_f,
        currency: "HTG",
        description: "Voye #{transfer.amount.to_i} HTG bay #{receiver_label}",
        reference_id: reference_id,
        callback_url: "#{ENV.fetch('APP_HOST', 'http://localhost:3000')}/bonid_consent_webhook"
      }.to_json
    end

    if response.status == 201
      data = JSON.parse(response.body)
      {
        success: true,
        consent_token: data["consent_token"],
        expires_at: data["expires_at"],
        ttl: data["ttl_seconds"]
      }
    else
      handle_error(response)
    end
  rescue Faraday::Error => e
    Rails.logger.error "BonID consent request failed: #{e.message}"
    { success: false, error: "Koneksyon ak BonID echwe. Tanpri eseye ankò." }
  end

  # Poll consent status (optional — webhook is primary)
  def self.check_consent(consent_token)
    response = connection.get("transaction_consents/#{consent_token}")

    if response.success?
      data = JSON.parse(response.body)
      {
        success: true,
        status: data["status"],
        signature: data["signature"],
        decided_at: data["decided_at"]
      }
    else
      handle_error(response)
    end
  rescue Faraday::Error => e
    Rails.logger.error "BonID consent check failed: #{e.message}"
    { success: false, error: e.message }
  end

  private

  def self.connection
    Faraday.new(url: "#{base_url}/") do |f|
      f.headers["X-Partner-Api-Key"] = api_key
      f.headers["Accept"] = "application/json"
      f.options.timeout = 10
      f.options.open_timeout = 5
      f.adapter Faraday.default_adapter
    end
  end

  def self.handle_error(response)
    body = JSON.parse(response.body) rescue {}
    case response.status
    when 401
      Rails.logger.error "BonID auth failed: #{body}"
      { success: false, error: "Otorizasyon BonID echwe. Kontakte sipò." }
    when 404
      { success: false, error: "BonID sa a pa egziste. Tcheke nimewo a epi eseye ankò." }
    when 429
      { success: false, error: "Twòp demann. Tanpri tann kèk minit epi eseye ankò." }
    else
      Rails.logger.error "BonID error #{response.status}: #{body}"
      { success: false, error: "Erè BonID (#{response.status}). Tanpri eseye ankò." }
    end
  end
end

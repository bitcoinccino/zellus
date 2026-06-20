class BonIdService
  BASE_URLS = {
    "production"  => "https://api.bonid.ht/api/v1",
    "sandbox"     => "https://sandbox.bonid.ht/api/v1",
    "development" => "https://bonid.ngrok.dev/api/v1"
  }.freeze

  def self.base_url
    raw = ENV.fetch("BONID_BASE_URL") { BASE_URLS[Rails.env] || BASE_URLS["sandbox"] }
    # Ensure the URL always ends with /api/v1
    raw.sub(%r{/?\z}, "").then { |u| u.match?(%r{/api/v\d+\z}) ? u : "#{u}/api/v1" }
  end

  # Bare BonID web host (no /api/v1) — for citizen-facing links like
  # /citizens/otp_sign_in and /citizens/sign_up. Mirrors how the OmniAuth
  # strategy derives its OAuth `site` from BONID_BASE_URL.
  def self.web_url
    base_url.sub(%r{/api/v\d+\z}, "")
  end

  def self.api_key
    ENV.fetch("BONID_API_KEY", "")
  end

  # Quick status check — returns { verified: true/false } or { error: "..." }
  def self.check_status(bonid)
    response = connection.get("identity/#{bonid}/status")

    if response.success?
      data = JSON.parse(response.body)
      # BonID API nests verified under "verification" object
      verified = if data["verification"].is_a?(Hash)
                   data["verification"]["verified"] == true
                 else
                   data["verified"] == true
                 end
      { success: true, verified: verified, bonid: data["bonid"] }
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

    # Prevent one BonID from being used on multiple accounts
    existing = User.where(bonid: result[:bonid]).where.not(id: user.id).first
    if existing
      return { success: false, error: "BonID sa a deja lye ak yon lòt kont Zèllus. Chak moun ka gen yon sèl kont." }
    end

    identity = result[:identity] || {}
    user.update!(
      bonid: result[:bonid],
      bonid_verified_at: Time.current,
      bonid_first_name: identity["first_name"],
      bonid_last_name: identity["last_name"],
      bonid_photo_url: identity["photo_url"],
      bonid_rechecked_at: Time.current
    )

    { success: true, identity: identity }
  end

  # Re-sync a verified user's BonID data from the API.
  # Called when user visits their BonID page (throttled to once per hour).
  # Updates stored fields if BonID data changed (e.g. name change → new prefix).
  # A 401 from BonID API means partner access was revoked — clears verification.
  def self.refresh_user!(user)
    return { success: false, error: "Pa gen BonID." } unless user.bonid.present?

    result = lookup(user.bonid)
    unless result[:success]
      # 401/403 = partner access revoked on BonID side → clear ALL verification
      if (result[:error]&.include?("Otorizasyon") || result[:error]&.include?("401")) && user.bonid.present?
        old_bonid = user.bonid
        user.update!(
          bonid: nil,
          bonid_verified_at: nil,
          bonid_first_name: nil,
          bonid_last_name: nil,
          bonid_photo_url: nil,
          bonid_street: nil,
          bonid_locality: nil,
          bonid_commune: nil,
          bonid_department: nil,
          bonid_country: nil,
          bonid_blood_type: nil,
          bonid_rechecked_at: nil
        )
        Rails.logger.warn "BonID REVOKED for #{old_bonid} — ALL fields cleared (API auth failure)"
        return { success: true, changes: { bonid_verified_at: nil }, revoked: true }
      end

      Rails.logger.warn "BonID refresh failed for #{user.bonid}: #{result[:error]}"
      return { success: false, error: result[:error] }
    end

    identity = result[:identity] || {}
    changes = {}

    # Check if BonID itself changed (prefix update after name change)
    if result[:bonid].present? && result[:bonid] != user.bonid
      changes[:bonid] = result[:bonid]
    end

    # Check identity fields for changes
    { bonid_first_name: "first_name", bonid_last_name: "last_name", bonid_photo_url: "photo_url" }.each do |col, key|
      new_val = identity[key]
      if new_val.present? && new_val != user.send(col)
        changes[col] = new_val
      end
    end

    # Check address fields if present
    %w[street locality commune department country].each do |field|
      col = :"bonid_#{field}"
      new_val = identity[field]
      if new_val.present? && new_val != user.send(col)
        changes[col] = new_val
      end
    end

    # If verification was revoked on BonID side — clear everything
    unless result[:verified]
      changes[:bonid] = nil
      changes[:bonid_verified_at] = nil
      changes[:bonid_first_name] = nil
      changes[:bonid_last_name] = nil
      changes[:bonid_photo_url] = nil
      changes[:bonid_street] = nil
      changes[:bonid_locality] = nil
      changes[:bonid_commune] = nil
      changes[:bonid_department] = nil
      changes[:bonid_country] = nil
      changes[:bonid_blood_type] = nil
      changes[:bonid_rechecked_at] = nil
    end

    changes[:bonid_rechecked_at] = Time.current
    user.update!(changes)

    Rails.logger.info "BonID refresh for #{user.bonid}: #{changes.keys.reject { |k| k == :bonid_rechecked_at }.join(', ').presence || 'no changes'}"
    { success: true, changes: changes.except(:bonid_rechecked_at) }
  end

  # ══════════════════════════════════════════════════
  # Per-Transaction Consent API
  # ══════════════════════════════════════════════════

  # Threshold in HTG — transfers at or above this require BonID consent.
  # USD transfers are converted to HTG equivalent (via RateService) before comparison.
  CONSENT_THRESHOLD = BigDecimal(ENV.fetch("BONID_CONSENT_THRESHOLD", "1000"))

  # Should this transfer require BonID consent?
  # Works for both HTG and USD transfers.
  # USD amounts are converted to their HTG equivalent using the current rate.
  # Returns true based on amount alone — caller must handle BonID presence check.
  def self.consent_required?(transfer)
    if transfer.usd_wallet_transfer? || transfer.usd_address_transfer?
      usd_amount = transfer.crypto_amount || transfer.net_amount || BigDecimal("0")
      htg_equivalent = usd_amount * RateService.buy_rate.to_d
      htg_equivalent >= CONSENT_THRESHOLD
    else
      transfer.amount >= CONSENT_THRESHOLD
    end
  end

  # Request consent for a transfer — returns consent_token + expiry
  # Supports both HTG and USD transfers.
  def self.request_consent(transfer)
    user = transfer.user
    return { success: false, error: "Itilizatè pa gen BonID" } unless user&.bonid.present?

    reference_id = "ZEL-transfer-#{transfer.token}"
    receiver_label = transfer.receiver_cashtag.present? ? "$#{transfer.receiver_cashtag}" : (transfer.receiver_name.presence || transfer.receiver_phone)

    # Determine currency + amount for the consent payload
    if transfer.usd_wallet_transfer? || transfer.usd_address_transfer?
      consent_amount = (transfer.crypto_amount || transfer.net_amount).to_f
      consent_currency = "USD"
      description = "Voye #{'%.2f' % consent_amount} USD bay #{receiver_label}"
    else
      consent_amount = transfer.amount.to_f
      consent_currency = "HTG"
      description = "Voye #{transfer.amount.to_i} HTG bay #{receiver_label}"
    end

    response = connection.post("transaction_consents") do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = {
        bonid: user.bonid,
        transaction_type: "p2p_transfer",
        scopes: ["identity"],
        amount: consent_amount,
        currency: consent_currency,
        description: description,
        reference_id: reference_id,
        callback_url: "#{ENV.fetch('APP_HOST', 'https://zellus.ht.ngrok.dev')}/bonid_consent_webhook"
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

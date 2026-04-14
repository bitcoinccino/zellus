# frozen_string_literal: true

# Lightspark Grid API wrapper for UMA inbound remittances.
#
# Mirrors CircleService style — class methods, Faraday, hash return values.
#
# Usage:
#   LightsparkService.create_customer(user)
#   LightsparkService.create_quote(amount_msats:, receiving_currency:, receiver_uma:)
#   LightsparkService.execute_quote(quote_id:)
#   LightsparkService.get_transaction(transaction_id)
#
class LightsparkService
  REQUEST_TIMEOUT = 30
  OPEN_TIMEOUT    = 10

  class LightsparkError < StandardError
    attr_reader :status, :code
    def initialize(message, status: nil, code: nil)
      @status = status
      @code   = code
      super(message)
    end
  end

  # ── Customer provisioning ──────────────────────────────────────────

  # Creates a Grid customer for a Zèllus user (idempotent via lightspark_customer_id).
  # Returns { customer_id: }.
  def self.create_customer(user)
    return { customer_id: user.lightspark_customer_id } if user.lightspark_customer_id.present?

    body = {
      external_id: user.id.to_s,
      name:        user.bonid_full_name || user.display_name,
      uma_address: user.uma_address
    }

    data = api_call(:post, "/customers", body: body)
    customer_id = data["id"]

    unless customer_id
      raise LightsparkError, "Grid create_customer returned no id (user #{user.id})"
    end

    user.update_column(:lightspark_customer_id, customer_id)
    { customer_id: customer_id }
  end

  # ── Quoting ────────────────────────────────────────────────────────

  # Locks an FX rate for an incoming UMA payment.
  # Returns { quote_id:, receiving_amount:, receiving_currency:, expires_at: }.
  def self.create_quote(amount_msats:, receiving_currency:, receiver_uma:)
    body = {
      sending_amount_msats: amount_msats,
      receiving_currency:   receiving_currency,
      receiver_uma_address: receiver_uma
    }

    data = api_call(:post, "/quotes", body: body)

    {
      quote_id:           data["id"],
      receiving_amount:   data["receiving_amount"],
      receiving_currency: data["receiving_currency"],
      expires_at:         data["expires_at"]
    }
  end

  # ── Payment execution ──────────────────────────────────────────────

  # Triggers payment for a locked quote.
  # Returns { payment_id:, status: }.
  def self.execute_quote(quote_id:)
    data = api_call(:post, "/quotes/#{quote_id}/execute")

    {
      payment_id: data["payment_id"] || data["id"],
      status:     data["status"]
    }
  end

  # ── Read operations ────────────────────────────────────────────────

  # Returns full transaction details by ID.
  def self.get_transaction(transaction_id)
    api_call(:get, "/transactions/#{transaction_id}")
  end

  # ── Private helpers ────────────────────────────────────────────────

  private_class_method def self.api_call(method, path, body: nil)
    conn = Faraday.new(url: LightsparkConfig::GRID_API_URL) do |f|
      f.options.timeout      = REQUEST_TIMEOUT
      f.options.open_timeout = OPEN_TIMEOUT
      f.request  :authorization, :basic,
                 LightsparkConfig::GRID_CLIENT_ID,
                 LightsparkConfig::GRID_CLIENT_SECRET
      f.adapter Faraday.default_adapter
    end

    response = conn.public_send(method, path) do |req|
      req.headers["Content-Type"] = "application/json"
      req.headers["Accept"]       = "application/json"
      req.body = body.to_json if body
    end

    parsed = JSON.parse(response.body) rescue {}

    unless response.success?
      msg  = parsed["message"] || parsed["error"] || "HTTP #{response.status}"
      code = parsed["code"]
      Rails.logger.error "LightsparkService #{method.upcase} #{path}: #{response.status} — #{msg}"
      raise LightsparkError.new("Grid API error: #{msg}", status: response.status, code: code)
    end

    Rails.logger.info "LightsparkService #{method.upcase} #{path}: #{response.status}"
    parsed
  end
end

# frozen_string_literal: true

# Circle Programmable Wallets (Developer-Controlled) API wrapper.
#
# Mirrors the style of MoncashService / BaseRpcClient — class methods,
# Faraday for HTTP, hash return values.
#
# Every write endpoint requires an RSA-OAEP-encrypted entitySecretCiphertext.
# We cache the ciphertext + Circle's public key for 60 seconds to avoid
# repeated RSA operations and /v1/w3s/config/entity/publicKey round-trips.
#
# Usage:
#   CircleService.create_wallet(user_id: user.id, idempotency_key: SecureRandom.uuid)
#   CircleService.send_usd(from_wallet_id: w, to_address: addr, amount: "10.50", idempotency_key: key)
#   CircleService.wallet_balance(wallet_id)
#
class CircleService
  REQUEST_TIMEOUT = 30
  OPEN_TIMEOUT    = 10

  class CircleError < StandardError
    attr_reader :status, :code
    def initialize(message, status: nil, code: nil)
      @status = status
      @code   = code
      super(message)
    end
  end

  # ── Wallet provisioning ──────────────────────────────────────────────

  # Creates a new developer-controlled wallet for a user.
  # Returns { wallet_id:, address: } on success.
  def self.create_wallet(user_id:, idempotency_key:)
    body = {
      idempotencyKey:         idempotency_key,
      entitySecretCiphertext: encrypted_entity_secret,
      blockchains:            [CircleConfig::BLOCKCHAIN],
      count:                  1,
      walletSetId:            CircleConfig::WALLET_SET_ID,
      metadata:               [{ name: "zellus_user_id", value: user_id.to_s }]
    }

    data = api_call(:post, "/v1/w3s/developer/wallets", body: body)
    wallet = data.dig("wallets")&.first

    unless wallet
      raise CircleError, "Circle create_wallet returned no wallet (user #{user_id})"
    end

    {
      wallet_id: wallet["id"],
      address:   wallet["address"]
    }
  end

  # ── Transfers ────────────────────────────────────────────────────────

  # Sends USD from a Circle wallet to an external blockchain address.
  def self.send_usd(from_wallet_id:, to_address:, amount:, idempotency_key:)
    body = {
      idempotencyKey:         idempotency_key,
      entitySecretCiphertext: encrypted_entity_secret,
      walletId:               from_wallet_id,
      tokenAddress:           usd_contract_address,
      destinationAddress:     to_address,
      blockchain:             CircleConfig::BLOCKCHAIN,
      amounts:                [amount.to_s],
      feeLevel:               "MEDIUM"
    }

    data = api_call(:post, "/v1/w3s/developer/transactions/transfer", body: body)
    tx   = data.dig("challengeId") ? data : (data.dig("transaction") || data)

    {
      success:        true,
      transaction_id: tx["id"],
      state:          tx["state"],
      data:           data
    }
  rescue CircleError => e
    { success: false, error: e.message }
  end

  # Wallet-to-wallet transfer (internal, instant, zero gas).
  def self.internal_transfer(from_wallet_id:, to_wallet_id:, amount:, idempotency_key:)
    body = {
      idempotencyKey:         idempotency_key,
      entitySecretCiphertext: encrypted_entity_secret,
      walletId:               from_wallet_id,
      tokenAddress:           usd_contract_address,
      destinationAddress:     wallet_address_for(to_wallet_id),
      blockchain:             CircleConfig::BLOCKCHAIN,
      amounts:                [amount.to_s],
      feeLevel:               "MEDIUM"
    }

    data = api_call(:post, "/v1/w3s/developer/transactions/transfer", body: body)
    tx   = data.dig("transaction") || data

    {
      success:        true,
      transaction_id: tx["id"],
      state:          tx["state"],
      data:           data
    }
  rescue CircleError => e
    { success: false, error: e.message }
  end

  # ── Read operations ──────────────────────────────────────────────────

  # Returns the USD balance for a Circle wallet (as BigDecimal).
  def self.wallet_balance(wallet_id)
    data = api_call(:get, "/v1/w3s/wallets/#{wallet_id}/balances")
    tokens = data.dig("tokenBalances") || []

    usdc = tokens.find { |t| t["token"]&.dig("blockchain") == CircleConfig::BLOCKCHAIN }
    BigDecimal(usdc&.dig("amount") || "0")
  end

  # Returns full transaction details by ID.
  def self.get_transaction(transaction_id)
    data = api_call(:get, "/v1/w3s/transactions/#{transaction_id}")
    data["transaction"] || data
  end

  # ── Entity secret encryption ─────────────────────────────────────────

  # Circle requires every write call to include the entity secret encrypted
  # with their RSA public key using OAEP/SHA-256.
  #
  # IMPORTANT: Circle rejects reused ciphertexts — each API call needs a
  # freshly encrypted value.  We cache only the RSA *public key* (60 s)
  # to avoid repeated /v1/w3s/config/entity/publicKey round-trips.
  def self.encrypted_entity_secret
    rsa_key    = cached_rsa_public_key
    raw_secret = [CircleConfig::ENTITY_SECRET].pack("H*") # hex → binary

    # Circle requires RSA-OAEP with SHA-256 for both hash and MGF1
    ciphertext = rsa_key.encrypt(raw_secret, {
      "rsa_padding_mode" => "oaep",
      "rsa_oaep_md"      => "sha256",
      "rsa_mgf1_md"      => "sha256"
    })

    Base64.strict_encode64(ciphertext)
  end

  # Cache Circle's RSA public key for 60 seconds to reduce HTTP calls.
  def self.cached_rsa_public_key
    @pubkey_mutex ||= Mutex.new

    @pubkey_mutex.synchronize do
      if @cached_rsa_key && @cached_key_at && (Time.now - @cached_key_at) < 60
        return @cached_rsa_key
      end

      public_key_pem = fetch_entity_public_key
      @cached_rsa_key  = OpenSSL::PKey::RSA.new(public_key_pem)
      @cached_key_at   = Time.now
      @cached_rsa_key
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  private_class_method def self.fetch_entity_public_key
    data = api_call(:get, "/v1/w3s/config/entity/publicKey")
    data["publicKey"] || raise(CircleError, "No publicKey in Circle response")
  end

  private_class_method def self.usd_contract_address
    # USD contract address per network.
    # Base Mainnet: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    # Base Sepolia: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
    ENV.fetch("CIRCLE_USDC_CONTRACT", CircleConfig::USD_TOKEN_ADDRESS)
  end

  private_class_method def self.wallet_address_for(wallet_id)
    data   = api_call(:get, "/v1/w3s/wallets/#{wallet_id}")
    wallet = data["wallet"] || data
    wallet["address"] || raise(CircleError, "No address for wallet #{wallet_id}")
  end

  # Shared Faraday HTTP wrapper.
  private_class_method def self.api_call(method, path, body: nil)
    conn = Faraday.new(url: CircleConfig::BASE_URL) do |f|
      f.options.timeout      = REQUEST_TIMEOUT
      f.options.open_timeout = OPEN_TIMEOUT
      f.adapter Faraday.default_adapter
    end

    response = conn.public_send(method, path) do |req|
      req.headers["Authorization"] = "Bearer #{CircleConfig::API_KEY}"
      req.headers["Content-Type"]  = "application/json"
      req.headers["Accept"]        = "application/json"
      req.body = body.to_json if body
    end

    parsed = JSON.parse(response.body) rescue {}
    data   = parsed["data"] || parsed

    unless response.success?
      msg  = parsed.dig("message") || parsed.dig("error") || "HTTP #{response.status}"
      code = parsed.dig("code")
      Rails.logger.error "CircleService #{method.upcase} #{path}: #{response.status} — #{msg}"
      raise CircleError.new("Circle API error: #{msg}", status: response.status, code: code)
    end

    data
  end

  # Reset cached values (useful in tests).
  def self.reset_cache!
    @cached_rsa_key  = nil
    @cached_key_at   = nil
    @usd_token_id   = nil
  end
end

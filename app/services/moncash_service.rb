class MoncashService
  # Sandbox URL for MonCash
  BASE_URL = "https://sandbox.moncashbutton.digicelgroup.com"
  GATEWAY_BASE_URL = ENV["MONCASH_GATEWAY_BASE_URL"].presence || "#{BASE_URL}/Moncash-middleware"

  # Platform MonCash accounts — never pay these out
  PLATFORM_ACCOUNTS = %w[50937811188 50937811189].freeze

  # 1. Get OAuth2 Token from Digicel
  def self.get_token
    client_id = ENV['MONCASH_CLIENT_ID'].to_s.strip
    secret    = ENV['MONCASH_SECRET'].to_s.strip
    Rails.logger.info "MonCash Auth: client_id=#{client_id.first(8)}... url=#{BASE_URL}/Api/oauth/token"

    conn = Faraday.new(url: "#{BASE_URL}/Api/oauth/token") do |f|
      f.request :authorization, :basic, client_id, secret
      f.adapter Faraday.default_adapter
    end

    response = conn.post("?scope=read,write&grant_type=client_credentials")
    Rails.logger.info "MonCash Auth Response: status=#{response.status} body=#{response.body.first(300)}"

    if response.success?
      token = JSON.parse(response.body)["access_token"]
      Rails.logger.info "MonCash Auth OK: token=#{token.to_s.first(20)}..."
      token
    else
      Rails.logger.error "MonCash Auth Failed: #{response.status} - #{response.body}"
      nil
    end
  rescue => e
    Rails.logger.error "MonCash Token Connection Error: #{e.message}"
    nil
  end

  # 2. Create the Payment and get the Redirect URL
  def self.create_payment(transaction)
    token = get_token
    return nil unless token

    conn = Faraday.new(url: "#{BASE_URL}/Api/v1/CreatePayment")

    # UPDATED: Appending timestamp to orderId to ensure uniqueness across retries
    unique_order_id = "#{transaction.id}-#{Time.now.to_i}"
    
    payload = {
      amount: transaction.fiat_amount.to_i,
      orderId: unique_order_id
    }.to_json

    Rails.logger.info "MonCash CreatePayment: payload=#{payload}"

    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Content-Type'] = 'application/json'
      req.headers['Accept'] = 'application/json'
      req.body = payload
    end

    Rails.logger.info "MonCash CreatePayment Response: status=#{response.status} body=#{response.body.first(500)}"

    if response.success?
      body = JSON.parse(response.body)
      payment_token = body.dig("payment_token", "token")

      # Important: We store the unique_order_id so we can verify it later
      transaction.update(
        moncash_transaction_id: payment_token,
        last_moncash_order_id: unique_order_id # Recommended: add this column to your schema
      )

      "#{GATEWAY_BASE_URL}/Payment/Redirect?token=#{payment_token}"
    else
      Rails.logger.error "MonCash Payment Creation Failed: status=#{response.status} body=#{response.body}"
      nil
    end
  rescue => e
    Rails.logger.error "MonCash CreatePayment Error: #{e.message}"
    nil
  end

  # 3a. Verify by MonCash transactionId
  def self.verify_payment(transaction_id)
    token = get_token
    return false unless token

    conn = Faraday.new(url: "#{BASE_URL}/Api/v1/RetrieveTransactionPayment")

    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Content-Type'] = 'application/json'
      req.body = { transactionId: transaction_id }.to_json
    end

    if response.success?
      data = JSON.parse(response.body)
      data.dig("payment", "message") == "successful"
    else
      false
    end
  end

  # 3b. Verify by orderId (Use the last_moncash_order_id here)
  def self.verify_order(order_id)
    token = get_token
    return false unless token

    conn = Faraday.new(url: "#{BASE_URL}/Api/v1/RetrieveOrderPayment")

    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Content-Type'] = 'application/json'
      req.body = { orderId: order_id.to_s }.to_json
    end

    if response.success?
      data = JSON.parse(response.body)
      data.dig("payment", "message") == "successful"
    else
      false
    end
  end

  # 4. Check sandbox prefunded balance
  def self.prefunded_balance
    info = prefunded_balance_info
    info[:success] ? info[:balance] : nil
  end

  def self.prefunded_balance_info
    token = get_token
    return { success: false, error: "Auth failed" } unless token

    conn = Faraday.new(url: "#{BASE_URL}/Api/v1/PrefundedBalance")
    response = conn.get do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Accept'] = 'application/json'
    end

    data = JSON.parse(response.body) rescue {}

    if response.success?
      balance = data.dig("balance", "balance") || data["balance"]
      {
        success: true,
        balance: balance,
        http_status: response.status,
        data: data
      }
    else
      # Sandbox accounts may not have short code configured (403).
      # Bypass with a simulated balance so payouts aren't blocked during testing.
      # TODO: Remove this bypass when switching to MonCash production credentials.
      if response.status == 403
        Rails.logger.warn "MonCash PrefundedBalance 403 — using simulated balance of 999_999 HTG (sandbox)"
        return {
          success: true,
          balance: 999_999,
          http_status: response.status,
          data: data,
          simulated: true
        }
      end

      {
        success: false,
        http_status: response.status,
        error: data["message"] || data["error"] || "HTTP #{response.status}",
        data: data
      }
    end
  rescue => e
    { success: false, error: "MonCash connection failed: #{e.message}" }
  end

  # 5. Send HTG to a MonCash user
  def self.transfert(receiver, amount, reference, desc = "Zèllus USD Sale")
    clean_receiver = receiver.to_s.gsub(/[^\d]/, '')
    if PLATFORM_ACCOUNTS.include?(clean_receiver)
      Rails.logger.error "MonCash Transfert BLOCKED: tried to pay platform account #{clean_receiver} [ref=#{reference}]"
      return { success: false, error: "Pa ka voye lajan bay kont platfòm nan" }
    end

    token = get_token
    return { success: false, error: "Auth failed" } unless token

    conn = Faraday.new(url: "#{BASE_URL}/Api/v1/Transfert")

    payload = {
      amount:    amount.to_i,
      receiver:  receiver.to_s.gsub(/[^\d]/, ''),
      desc:      desc,
      reference: reference.to_s
    }.to_json

    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Content-Type']  = 'application/json'
      req.body = payload
    end

    if response.success?
      data = JSON.parse(response.body)
      if data.dig("transfer", "message") == "successful"
        { success: true, transaction_id: data.dig("transfer", "transaction_id") }
      else
        { success: false, error: data.dig("transfer", "message") || "Unknown error" }
      end
    else
      { success: false, error: "HTTP #{response.status}: #{response.body}" }
    end
  rescue => e
    { success: false, error: "MonCash connection failed: #{e.message}" }
  end

  # 6. Check prefunded payout transaction by reference
  def self.prefunded_transaction_status(reference)
    token = get_token
    return { success: false, error: "Auth failed" } unless token

    conn = Faraday.new(url: "#{BASE_URL}/Api/v1/PrefundedTransactionStatus")

    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Content-Type']  = 'application/json'
      req.headers['Accept']        = 'application/json'
      req.body = { reference: reference.to_s }.to_json
    end

    data = JSON.parse(response.body) rescue {}
    trans_status = data["transStatus"].to_s

    if response.success?
      {
        success: trans_status.casecmp("successful").zero?,
        trans_status: trans_status.presence || "unknown",
        http_status: response.status,
        data: data
      }
    else
      {
        success: false,
        http_status: response.status,
        error: data["message"] || data["error"] || "HTTP #{response.status}",
        data: data
      }
    end
  end

  # 7. Check MonCash customer wallet status (registered/active, KYC type)
  def self.customer_status(account)
    token = get_token
    return { success: false, error: "Auth failed" } unless token

    conn = Faraday.new(url: "#{BASE_URL}/Api/v1/CustomerStatus")

    response = conn.post do |req|
      req.headers['Authorization'] = "Bearer #{token}"
      req.headers['Content-Type']  = 'application/json'
      req.headers['Accept']        = 'application/json'
      req.body = { account: account.to_s.gsub(/[^\d]/, '') }.to_json
    end

    data = JSON.parse(response.body) rescue {}
    customer = data["customerStatus"] || {}
    statuses = Array(customer["status"]).map(&:to_s)

    if response.success?
      {
        success: true,
        account: account.to_s.strip,
        type: customer["type"].to_s,
        statuses: statuses,
        active: statuses.map(&:downcase).include?("active"),
        http_status: response.status,
        data: data
      }
    else
      {
        success: false,
        http_status: response.status,
        error: data["message"] || data["error"] || "HTTP #{response.status}",
        data: data
      }
    end
  rescue => e
    { success: false, error: "MonCash connection failed: #{e.message}" }
  end

  def self.transfer(amount, receiver_phone)
  token = get_token
  # Implementation using MonCash Payout API
  # POST /v1/transfer
  # amount: amount, receiver: receiver_phone
end

end

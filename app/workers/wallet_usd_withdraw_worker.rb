# frozen_string_literal: true

require "sidekiq"
require "faraday"

class WalletUsdWithdrawWorker
  include Sidekiq::Job
  sidekiq_options retry: 0  # No retries — on-chain txs are not idempotent

  # Base Mainnet
  CHAIN_ID          = 8453
  USD_ADDRESS      = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  TRANSFER_SELECTOR = "a9059cbb"
  MAX_SIGN_ATTEMPTS = 5

  # Sends USD from treasury to an external wallet address.
  # amount is in USD (decimal), e.g. 5.0
  # Gas cap: 500 gwei
  MAX_GAS_PRICE = 500_000_000_000

  def perform(user_id, amount, to_address, _asset = "usd")
    user   = User.find(user_id)
    wallet = user.wallet
    return unless wallet

    amount = amount.to_d

    # Validate address before anything else
    EthAddressValidator.validate!(to_address)

    if CryptoProvider.circle? && user.circle_wallet_id.present?
      perform_circle(user, wallet, amount, to_address)
    else
      perform_self_hosted(user, wallet, amount, to_address)
    end
  end

  private

  def perform_circle(user, wallet, amount, to_address)
    result = CircleService.send_usdc(
      from_wallet_id:  user.circle_wallet_id,
      to_address:      to_address,
      amount:          amount,
      idempotency_key: SecureRandom.uuid
    )

    if result[:success]
      entry = wallet.wallet_ledger_entries.withdrawals.usd_entries.order(created_at: :desc).first
      entry&.update(circle_transfer_id: result[:transaction_id])

      Rails.logger.info "WalletUsdWithdraw: Circle send ok [user=#{user.id}] tx=#{result[:transaction_id]}"
      notify_withdrawal_sent(user, amount, to_address, result[:transaction_id])
    else
      Rails.logger.error "WalletUsdWithdraw: Circle failed [user=#{user.id}]: #{result[:error]}"
      # Refund since Circle call failed before any broadcast
      WalletService.new(wallet).refund!(
        amount: amount,
        asset: "usd",
        reason: "Retrè USD echwe — ranbouse #{amount} USD"
      )
      Rails.logger.info "WalletUsdWithdraw: refunded #{amount} USD [user=#{user.id}]"
      notify_withdrawal_failed(user, amount, result[:error])
    end
  rescue => e
    Rails.logger.error "WalletUsdWithdraw Circle error [user=#{user.id}]: #{e.message}"
    begin
      WalletService.new(wallet).refund!(
        amount: amount,
        asset: "usd",
        reason: "Retrè USD echwe — ranbouse #{amount} USD"
      )
      notify_withdrawal_failed(user, amount, e.message)
    rescue => refund_error
      Rails.logger.error "WalletUsdWithdraw refund failed [user=#{user.id}]: #{refund_error.message}"
    end
  end

  def perform_self_hosted(user, wallet, amount, to_address)
    require "digest/keccak"
    require "openssl"

    tx_hash = nil
    broadcast_attempted = false

    rpc_url  = ENV["BASE_RPC_URL"].presence || "https://mainnet.base.org"
    priv_hex = ENV["TREASURY_PRIVATE_KEY"].to_s.strip.delete_prefix("0x")
    raise "TREASURY_PRIVATE_KEY not set" if priv_hex.empty?

    key    = build_ec_key(priv_hex)
    sender = derive_address(key)

    TreasuryNonceLock.with_nonce(rpc_url, sender) do |nonce|
      base_price = rpc_call(rpc_url, "eth_gasPrice", []).to_i(16)
      gas_price  = [ base_price * 2, MAX_GAS_PRICE ].min

      amount_units = (amount * 10**6).to_i
      calldata     = build_transfer_calldata(to_address, amount_units)
      gas_limit    = estimate_gas(rpc_url, sender, USD_ADDRESS, calldata)

      Rails.logger.info "WalletUsdWithdraw: signing USD tx [user=#{user.id}]"

      raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                  to: USD_ADDRESS, data: calldata, key: key)

      broadcast_attempted = true
      tx_hash = rpc_call(rpc_url, "eth_sendRawTransaction", [ "0x#{raw_tx}" ])
      raise "RPC returned no tx hash" if tx_hash.blank?
    end

    # Mark the withdrawal ledger entry with the on-chain tx hash
    entry = wallet.wallet_ledger_entries.withdrawals.usd_entries.order(created_at: :desc).first
    entry&.update(moncash_transaction_id: tx_hash)

    Rails.logger.info "WalletUsdWithdraw: broadcast ok [user=#{user.id}]"
    notify_withdrawal_sent(user, amount, to_address, tx_hash)

  rescue => e
    Rails.logger.error "WalletUsdWithdraw error [user=#{user.id}]: #{e.message}"

    # Only refund if we are CERTAIN the tx was NOT broadcast
    if !broadcast_attempted || tx_hash.blank?
      begin
        if wallet
          WalletService.new(wallet).refund!(
            amount: amount,
            asset: "usd",
            reason: "Retrè USD echwe — ranbouse #{amount} USD"
          )
          Rails.logger.info "WalletUsdWithdraw: refunded #{amount} USD [user=#{user.id}]"
          notify_withdrawal_failed(user, amount, e.message)
        end
      rescue => refund_error
        Rails.logger.error "WalletUsdWithdraw refund failed [user=#{user.id}]: #{refund_error.message}"
      end
    else
      # Tx was broadcast but we got an error after — DO NOT refund, flag for manual review
      Rails.logger.error "WalletUsdWithdraw: tx broadcast attempted (#{tx_hash || 'unknown'}), NOT refunding — needs manual review [user=#{user.id}]"
    end
  end

  def notify_withdrawal_sent(user, amount, to_address, tx_hash)
    user = User.find(user) if user.is_a?(Integer)
    WalletMailer.with(user_id: user.id, amount: amount.to_f, asset: "usd", tx_hash: tx_hash, to_address: to_address)
               .withdrawal_sent.deliver_later
    NotificationService.crypto_withdrawal_sent(user, amount, "usd", tx_hash)
    WebhookService.dispatch("withdrawal.completed", user: user, payload: {
      amount: amount.to_s, asset: "usd", method: "crypto", to_address: to_address, tx_hash: tx_hash
    })
  rescue => e
    Rails.logger.error "WalletUsdWithdraw: withdrawal_sent notification failed [user=#{user.try(:id)}]: #{e.message}"
  end

  def notify_withdrawal_failed(user, amount, reason)
    user = User.find(user) if user.is_a?(Integer)
    clean_reason = humanize_rpc_error(reason)
    WalletMailer.with(user_id: user.id, amount: amount.to_f, asset: "usd", reason: clean_reason)
               .withdrawal_failed.deliver_later
    NotificationService.crypto_withdrawal_failed(user, amount, "usd", clean_reason)
    WebhookService.dispatch("withdrawal.failed", user: user, payload: {
      amount: amount.to_s, asset: "usd", method: "crypto", reason: clean_reason
    })
  rescue => e
    Rails.logger.error "WalletUsdWithdraw: withdrawal_failed notification failed [user=#{user.try(:id)}]: #{e.message}"
  end

  private

  # Convert raw RPC/blockchain errors into human-readable Creole messages
  def humanize_rpc_error(raw)
    msg = raw.to_s.downcase
    if msg.include?("transfer amount exceeds balance")
      "Retrè a pa t kapab trete kounye a. Tanpri eseye ankò pita oswa kontakte sipò."
    elsif msg.include?("insufficient funds")
      "Pa gen ase fon pou peye frè gaz. Tanpri eseye ankò pita."
    elsif msg.include?("nonce too low")
      "Tranzaksyon an te an konfli. Tanpri eseye ankò."
    elsif msg.include?("gas required exceeds allowance") || msg.include?("out of gas")
      "Frè gaz twò wo kounye a. Tanpri eseye ankò pita."
    elsif msg.include?("execution reverted")
      "Tranzaksyon an pa t kapab trete sou blockchain la. Tanpri kontakte sipò."
    elsif msg.include?("timeout") || msg.include?("connection")
      "Pa t kapab konekte ak rezo blockchain la. Tanpri eseye ankò pita."
    else
      "Yon erè teknik te fèt. Tanpri eseye ankò oswa kontakte sipò."
    end
  end

  # ── Crypto helpers ──────────────────────────────────────────────────────

  def build_ec_key(priv_hex)
    priv_hex  = priv_hex.rjust(64, "0")
    priv_bn   = OpenSSL::BN.new(priv_hex, 16)
    group     = OpenSSL::PKey::EC::Group.new("secp256k1")
    pub_point = group.generator.mul(priv_bn)
    priv_bytes = [ priv_hex ].pack("H*")
    pub_bytes  = pub_point.to_octet_string(:uncompressed)

    der = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Integer(OpenSSL::BN.new(1)),
      OpenSSL::ASN1::OctetString(priv_bytes),
      OpenSSL::ASN1::ASN1Data.new([ OpenSSL::ASN1::ObjectId("secp256k1") ], 0, :CONTEXT_SPECIFIC),
      OpenSSL::ASN1::ASN1Data.new([ OpenSSL::ASN1::BitString(pub_bytes) ],  1, :CONTEXT_SPECIFIC)
    ]).to_der

    OpenSSL::PKey::EC.new(der)
  end

  def derive_address(key)
    pub_bytes = key.public_key.to_octet_string(:uncompressed)[1..]
    addr_hash = Digest::Keccak.digest(pub_bytes, 256)
    "0x" + addr_hash.unpack1("H*")[-40..]
  end

  def build_transfer_calldata(to_address, amount_units)
    addr_padded   = to_address.delete_prefix("0x").downcase.rjust(64, "0")
    amount_padded = amount_units.to_s(16).rjust(64, "0")
    TRANSFER_SELECTOR + addr_padded + amount_padded
  end

  def build_and_sign_tx(nonce:, gas_price:, gas_limit:, to:, data:, key:, value: 0)
    to_bytes   = [ to.delete_prefix("0x") ].pack("H*")
    data_bytes = data.empty? ? "".b : [ data ].pack("H*")

    unsigned = rlp_encode([
      encode_int(nonce), encode_int(gas_price), encode_int(gas_limit),
      to_bytes, encode_int(value), data_bytes,
      encode_int(CHAIN_ID), "".b, "".b
    ])

    hash  = Digest::Keccak.digest(unsigned, 256)
    r, s, v = sign_hash_with_retry(hash, key)

    rlp_encode([
      encode_int(nonce), encode_int(gas_price), encode_int(gas_limit),
      to_bytes, encode_int(value), data_bytes,
      encode_int(v), encode_int(r), encode_int(s)
    ]).unpack1("H*")
  end

  # Retry signing up to MAX_SIGN_ATTEMPTS times.
  # OpenSSL ECDSA uses a random nonce k each time, so recovery_id may fail
  # for one signature but succeed on the next attempt.
  def sign_hash_with_retry(hash_bytes, key)
    last_error = nil
    MAX_SIGN_ATTEMPTS.times do |attempt|
      begin
        return sign_hash(hash_bytes, key)
      rescue => e
        last_error = e
        Rails.logger.warn "WalletUsdWithdraw: signing attempt #{attempt + 1} failed: #{e.message}, retrying..."
      end
    end
    raise last_error
  end

  def sign_hash(hash_bytes, key)
    sig_der = key.dsa_sign_asn1(hash_bytes)
    asn1    = OpenSSL::ASN1.decode(sig_der)
    r       = asn1.value[0].value.to_i
    s       = asn1.value[1].value.to_i

    group_order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    s = group_order - s if s > group_order / 2

    rec_id = recovery_id(hash_bytes, r, s, key)
    v = rec_id + CHAIN_ID * 2 + 35

    [ r, s, v ]
  end

  def recovery_id(hash_bytes, r, s, key)
    expected = key.public_key.to_octet_string(:uncompressed)[1..].unpack1("H*")
    [ 0, 1, 2, 3 ].each do |i|
      candidate = recover_public_key(hash_bytes, r, s, i)
      return i if candidate == expected
    end
    raise "ECDSA recovery failed: could not recover public key from signature."
  end

  def recover_public_key(hash_bytes, r, s, rec_id)
    p_val  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
    order  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    hash_n = hash_bytes.unpack1("H*").to_i(16)

    x    = r + rec_id * order
    return nil if x >= p_val

    y_sq = (x.pow(3, p_val) + 7) % p_val
    y    = y_sq.pow((p_val + 1) / 4, p_val)
    y    = p_val - y if (y % 2) != (rec_id % 2)

    point_hex = "04" + x.to_s(16).rjust(64, "0") + y.to_s(16).rjust(64, "0")
    group     = OpenSSL::PKey::EC::Group.new("secp256k1")
    point     = OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(point_hex, 16))

    r_inv    = r.pow(order - 2, order)
    neg_hash = (order - hash_n % order) % order

    recovered = point.mul(OpenSSL::BN.new(s.to_s(16), 16))
                     .add(group.generator.mul(OpenSSL::BN.new(neg_hash.to_s(16), 16)))
                     .mul(OpenSSL::BN.new(r_inv.to_s(16), 16))

    recovered.to_octet_string(:uncompressed)[1..].unpack1("H*")
  rescue
    nil
  end

  # ── RLP encoding ────────────────────────────────────────────────────────

  def rlp_encode(value)
    case value
    when Array
      items = value.map { |i| rlp_encode(i) }.join.b
      rlp_length(items.bytesize, 0xc0) + items
    when String
      bytes = value.b
      if bytes.bytesize == 1 && bytes.getbyte(0) < 0x80
        bytes
      else
        rlp_length(bytes.bytesize, 0x80) + bytes
      end
    end
  end

  def rlp_length(len, offset)
    if len < 56
      (offset + len).chr.b
    else
      len_bytes = encode_int(len)
      (offset + 55 + len_bytes.bytesize).chr.b + len_bytes
    end
  end

  def encode_int(n)
    return "".b if n == 0
    hex = n.to_s(16)
    hex = "0#{hex}" if hex.length.odd?
    [ hex ].pack("H*").b
  end

  # ── JSON-RPC (delegated to BaseRpcClient with retry/backoff) ──────────

  def rpc_call(url, method, params)
    @rpc_client ||= BaseRpcClient.new(url: url)
    @rpc_client.call(method, params)
  end

  def estimate_gas(url, from, to, data)
    result = rpc_call(url, "eth_estimateGas", [ {
      from: from, to: to, data: "0x#{data}", value: "0x0"
    } ])
    (result.to_i(16) * 1.2).to_i
  end
end

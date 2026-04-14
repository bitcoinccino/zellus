# frozen_string_literal: true
require 'sidekiq'
require 'digest/keccak'
require 'openssl'
require 'faraday'

class CryptoTransferWorker
  include Sidekiq::Job

  # Base Mainnet chain ID
  CHAIN_ID     = 8453
  # USD (USD) on Base Mainnet (6 decimals)
  USD_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  # WBTC on Base Mainnet (8 decimals)
  WBTC_ADDRESS = ENV.fetch("WBTC_CONTRACT_ADDRESS", "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c")
  # keccak256("transfer(address,uint256)")[0..3] — fixed ABI selector
  TRANSFER_SELECTOR = "a9059cbb"

  # Gas cap: 500 gwei
  MAX_GAS_PRICE = 500_000_000_000

  def perform(transaction_id)
    transaction = Transaction.find(transaction_id)
    return unless transaction.paid?
    return if transaction.blockchain_tx_hash.present?

    # Validate destination address
    EthAddressValidator.validate!(transaction.destination_address)

    rpc_url  = ENV['BASE_RPC_URL'].presence || "https://mainnet.base.org"
    priv_hex = ENV['TREASURY_PRIVATE_KEY'].to_s.strip.delete_prefix("0x")
    raise "TREASURY_PRIVATE_KEY not set" if priv_hex.empty?

    key    = build_ec_key(priv_hex)
    sender = derive_address(key)
    is_eth  = transaction.respond_to?(:eth?)  && transaction.eth?
    is_wbtc = transaction.respond_to?(:wbtc?) && transaction.wbtc?

    # ETH/wBTC transfers disabled (HTG + USD only mode)
    if is_eth || is_wbtc
      Rails.logger.warn "CryptoTransfer: ETH/WBTC disabled (HTG+USD only mode) [tx=#{transaction_id}]"
      transaction.update!(status: :failed, failure_reason: "ETH/WBTC transfers paused — HTG+USD only mode")
      return
    end

    TreasuryNonceLock.with_nonce(rpc_url, sender) do |nonce|
      base_price = rpc_call(rpc_url, "eth_gasPrice", []).to_i(16)
      gas_price  = [base_price * 2, MAX_GAS_PRICE].min

      if is_eth
        amount    = (transaction.crypto_amount * 10**18).to_i
        gas_limit = 21_000
        raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                    to: transaction.destination_address, data: "", value: amount, key: key)
      elsif is_wbtc
        amount    = (transaction.crypto_amount * 10**8).to_i
        calldata  = build_transfer_calldata(transaction.destination_address, amount)
        gas_limit = estimate_gas(rpc_url, sender, WBTC_ADDRESS, calldata)
        raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                    to: WBTC_ADDRESS, data: calldata, key: key)
      else
        amount    = (transaction.crypto_amount * 10**6).to_i
        calldata  = build_transfer_calldata(transaction.destination_address, amount)
        gas_limit = estimate_gas(rpc_url, sender, USD_ADDRESS, calldata)
        raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                    to: USD_ADDRESS, data: calldata, key: key)
      end

      Rails.logger.info "CryptoTransfer: signing tx [tx=#{transaction_id}]"

      tx_hash = rpc_call(rpc_url, "eth_sendRawTransaction", ["0x#{raw_tx}"])
      raise "RPC returned no tx hash" if tx_hash.blank?

      currency = is_eth ? "ETH" : is_wbtc ? "WBTC" : "USD"
      transaction.update!(blockchain_tx_hash: tx_hash, status: :crypto_sent)
      Rails.logger.info "CryptoTransfer: broadcast ok #{currency} [tx=#{transaction_id}]"

      TransactionConfirmationWorker.perform_in(15.seconds, transaction.id)
    end

  rescue => e
    notify_failure = false
    begin
      if transaction
        notify_failure = !transaction.failed?
        transaction.update!(status: :failed, failure_reason: e.message)
      end
    rescue
      nil
    end
    if notify_failure && transaction
      notify_transaction_email(:failed, transaction)
      NotificationService.transaction_failed(transaction)
    end
    Rails.logger.error "Zèllus CryptoTransfer failed [tx=#{transaction_id}]: #{e.message}"
    raise
  end

  private

  # ── Key helpers ──────────────────────────────────────────────────────────

  def build_ec_key(priv_hex)
    priv_hex  = priv_hex.rjust(64, '0')
    priv_bn   = OpenSSL::BN.new(priv_hex, 16)
    group     = OpenSSL::PKey::EC::Group.new('secp256k1')
    pub_point = group.generator.mul(priv_bn)
    priv_bytes = [priv_hex].pack('H*')
    pub_bytes  = pub_point.to_octet_string(:uncompressed)

    der = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Integer(OpenSSL::BN.new(1)),
      OpenSSL::ASN1::OctetString(priv_bytes),
      OpenSSL::ASN1::ASN1Data.new([OpenSSL::ASN1::ObjectId('secp256k1')], 0, :CONTEXT_SPECIFIC),
      OpenSSL::ASN1::ASN1Data.new([OpenSSL::ASN1::BitString(pub_bytes)],  1, :CONTEXT_SPECIFIC)
    ]).to_der

    OpenSSL::PKey::EC.new(der)
  end

  def derive_address(key)
    pub_bytes = key.public_key.to_octet_string(:uncompressed)[1..] # drop 0x04 prefix
    addr_hash = Digest::Keccak.digest(pub_bytes, 256)
    "0x" + addr_hash.unpack1('H*')[-40..]
  end

  # ── ERC-20 calldata ──────────────────────────────────────────────────────

  def build_transfer_calldata(to_address, amount_units)
    addr_padded   = to_address.delete_prefix("0x").downcase.rjust(64, '0')
    amount_padded = amount_units.to_s(16).rjust(64, '0')
    TRANSFER_SELECTOR + addr_padded + amount_padded
  end

  # ── Transaction building & signing (EIP-155 legacy tx) ───────────────────

  def build_and_sign_tx(nonce:, gas_price:, gas_limit:, to:, data:, key:, value: 0)
    to_bytes   = [to.delete_prefix("0x")].pack('H*')
    data_bytes = data.empty? ? "".b : [data].pack('H*')

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
    ]).unpack1('H*')
  end

  # Retry signing up to 5 times — OpenSSL ECDSA uses a random nonce k,
  # so recovery_id may fail for one signature but succeed on the next.
  def sign_hash_with_retry(hash_bytes, key, max_attempts: 5)
    last_error = nil
    max_attempts.times do |attempt|
      begin
        return sign_hash(hash_bytes, key)
      rescue => e
        last_error = e
        Rails.logger.warn "CryptoTransfer: signing attempt #{attempt + 1} failed: #{e.message}, retrying..."
      end
    end
    raise last_error
  end

  def sign_hash(hash_bytes, key)
    sig_der = key.dsa_sign_asn1(hash_bytes)
    asn1    = OpenSSL::ASN1.decode(sig_der)
    r       = asn1.value[0].value.to_i
    s       = asn1.value[1].value.to_i

    # Enforce low-S canonical form (EIP-2)
    group_order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    s = group_order - s if s > group_order / 2

    rec_id = recovery_id(hash_bytes, r, s, key)
    v = rec_id + CHAIN_ID * 2 + 35

    [r, s, v]
  end

  def recovery_id(hash_bytes, r, s, key)
    expected = key.public_key.to_octet_string(:uncompressed)[1..].unpack1('H*')
    # Try all valid recovery ids (0..3). Some signatures produce x = r + n.
    [0, 1, 2, 3].each do |i|
      candidate = recover_public_key(hash_bytes, r, s, i)
      return i if candidate == expected
    end
    # Neither rec_id matched — this means the signature is invalid for this key.
    # Raise explicitly so we don't broadcast a tx with the wrong sender.
    raise "ECDSA recovery failed: could not recover public key from signature. Possible key encoding issue."
  end

  def recover_public_key(hash_bytes, r, s, rec_id)
    p_val  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
    order  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    hash_n = hash_bytes.unpack1('H*').to_i(16)

    x    = r + rec_id * order
    return nil if x >= p_val

    y_sq = (x.pow(3, p_val) + 7) % p_val
    y    = y_sq.pow((p_val + 1) / 4, p_val)
    y    = p_val - y if (y % 2) != (rec_id % 2)

    point_hex = "04" + x.to_s(16).rjust(64, '0') + y.to_s(16).rjust(64, '0')
    group     = OpenSSL::PKey::EC::Group.new('secp256k1')
    point     = OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(point_hex, 16))

    r_inv    = r.pow(order - 2, order)
    neg_hash = (order - hash_n % order) % order

    recovered = point.mul(OpenSSL::BN.new(s.to_s(16), 16))
                     .add(group.generator.mul(OpenSSL::BN.new(neg_hash.to_s(16), 16)))
                     .mul(OpenSSL::BN.new(r_inv.to_s(16), 16))

    recovered.to_octet_string(:uncompressed)[1..].unpack1('H*')
  rescue
    nil
  end

  # ── RLP encoding ─────────────────────────────────────────────────────────

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
    [hex].pack('H*').b
  end

  # ── JSON-RPC (delegated to BaseRpcClient with retry/backoff) ──────────

  def rpc_call(url, method, params)
    @rpc_client ||= BaseRpcClient.new(url: url)
    @rpc_client.call(method, params)
  end

  def estimate_gas(url, from, to, data)
    result = rpc_call(url, "eth_estimateGas", [{
      from: from, to: to, data: "0x#{data}", value: "0x0"
    }])
    (result.to_i(16) * 1.2).to_i
  end

  def notify_transaction_email(kind, transaction)
    TransactionMailer.with(transaction_id: transaction.id).public_send(kind).deliver_now
  rescue => e
    Rails.logger.error "Transaction #{kind} email failed [tx=#{transaction.id}]: #{e.message}"
  end
end

# frozen_string_literal: true
require 'sidekiq'
require 'faraday'

class TransferPayoutWorker
  include Sidekiq::Job

  # Base Sepolia (same constants as CryptoTransferWorker)
  CHAIN_ID     = 84532
  USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  WBTC_ADDRESS = ENV.fetch("WBTC_CONTRACT_ADDRESS", "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c")
  TRANSFER_SELECTOR = "a9059cbb"

  def perform(transfer_id)
    transfer = Transfer.find(transfer_id)

    # Only process funded or claimed transfers
    return unless transfer.funded? || transfer.claimed?

    if transfer.htg_transfer?
      process_htg_payout(transfer)
    else
      process_crypto_payout(transfer)
    end

  rescue => e
    Rails.logger.error "TransferPayout error [transfer=#{transfer_id}]: #{e.message}"
    begin
      transfer&.update!(status: :failed, failure_reason: e.message) if transfer && !transfer.completed?
    rescue
      nil
    end
    raise
  end

  private

  # ── HTG: MonCash Payout ──────────────────────────────────────────────────

  def process_htg_payout(transfer)
    # ── Auto-credit registered receiver's wallet ──
    receiver_user = find_receiver_user(transfer)
    if receiver_user.present?
      begin
        receiver_wallet = receiver_user.ensure_wallet!
        WalletService.new(receiver_wallet).transfer_in!(
          amount: transfer.net_amount,
          transfer: transfer,
          sender_user: transfer.user
        )
        transfer.update!(
          status: :completed,
          completed_at: Time.current,
          payout_method: "wallet"
        )
        notify_sender_completed(transfer)
        notify_receiver_completed(transfer)
        Rails.logger.info "TransferPayout: #{transfer.net_amount} HTG credited to wallet of user=#{receiver_user.id} [transfer=#{transfer.id}]"
        return
      rescue => e
        Rails.logger.warn "TransferPayout: wallet credit failed for user=#{receiver_user.id}, falling back to MonCash [transfer=#{transfer.id}]: #{e.message}"
        # Fall through to MonCash payout
      end
    end

    # ── MonCash payout (existing path) ──

    # Need receiver phone to send MonCash
    if transfer.receiver_phone.blank?
      Rails.logger.info "TransferPayout: transfer=#{transfer.id} waiting for receiver to claim (no phone)"
      return
    end

    payout_reference = "priotelus-transfer-#{transfer.id}"

    # 1. Verify MonCash receiver is active
    customer_check = MoncashService.customer_status(transfer.receiver_phone)
    unless customer_check[:success] && customer_check[:active]
      mark_failed_and_refund!(transfer, "MonCash: Kont moun nan pa aktif")
      Rails.logger.error "TransferPayout: receiver #{transfer.receiver_phone} not active [transfer=#{transfer.id}]"
      return
    end

    # 2. Send MonCash payout (net_amount = amount minus platform fee)
    transfer.update!(status: :sent)
    result = MoncashService.transfert(
      transfer.receiver_phone,
      transfer.net_amount.to_i,
      payout_reference,
      "Priotelus Zellus Transfer"
    )

    if result[:success]
      transfer.update!(
        status: :completed,
        completed_at: Time.current,
        moncash_transaction_id: result[:transaction_id]
      )
      notify_sender_completed(transfer)
      notify_receiver_completed(transfer)
      Rails.logger.info "TransferPayout: #{transfer.net_amount} HTG sent to #{transfer.receiver_phone} [transfer=#{transfer.id}]"
    else
      # Ambiguous error: check if payout actually went through
      status_check = MoncashService.prefunded_transaction_status(payout_reference)
      if status_check[:success]
        transfer.update!(status: :completed, completed_at: Time.current)
        notify_sender_completed(transfer)
        notify_receiver_completed(transfer)
        Rails.logger.info "TransferPayout: ambiguous success confirmed [transfer=#{transfer.id}]"
      else
        mark_failed_and_refund!(transfer, "MonCash echwe: #{result[:error]}")
        Rails.logger.error "TransferPayout: payout failed [transfer=#{transfer.id}]: #{result[:error]}"
      end
    end
  end

  # ── Find receiver by email or phone (for auto wallet credit) ──
  def find_receiver_user(transfer)
    # 1. Try matching by email
    if transfer.receiver_email.present?
      user = User.find_by(email: transfer.receiver_email)
      return user if user && user.id != transfer.user_id
    end

    # 2. Try matching by phone via payment_methods
    if transfer.receiver_phone.present?
      pm = PaymentMethod.where(active: true, category: "mobile_wallet", provider: "moncash")
                        .where(account_number: transfer.receiver_phone)
                        .first
      return pm.user if pm && pm.user_id != transfer.user_id
    end

    nil
  end

  # ── Mark transfer failed and refund sender's wallet if wallet-funded ──
  def mark_failed_and_refund!(transfer, reason)
    transfer.update!(status: :failed, failure_reason: reason)
    notify_sender_failed(transfer)

    if transfer.wallet_funded?
      begin
        sender_wallet = transfer.user.wallet
        if sender_wallet
          WalletService.new(sender_wallet).refund!(
            amount: transfer.amount,
            reference: transfer,
            reason: "Transfè echwe — ranbousman otomatik"
          )
          Rails.logger.info "TransferPayout: refunded #{transfer.amount} HTG to sender wallet [transfer=#{transfer.id}]"
        end
      rescue => e
        Rails.logger.error "TransferPayout: wallet refund failed [transfer=#{transfer.id}]: #{e.message}"
      end
    end
  end

  # ── Crypto: Send USDC/ETH/WBTC from Treasury ────────────────────────────

  def process_crypto_payout(transfer)
    require 'digest/keccak'
    require 'openssl'

    unless transfer.receiver_wallet_address.present?
      Rails.logger.error "TransferPayout: no wallet address [transfer=#{transfer.id}]"
      transfer.update!(status: :failed, failure_reason: "Pa gen adrès wallet")
      notify_sender_failed(transfer)
      return
    end

    unless transfer.crypto_amount.present? && transfer.crypto_amount > 0
      Rails.logger.error "TransferPayout: no crypto amount [transfer=#{transfer.id}]"
      transfer.update!(status: :failed, failure_reason: "Pa gen montan kripto")
      notify_sender_failed(transfer)
      return
    end

    rpc_url  = ENV['BASE_RPC_URL'].presence || "https://sepolia.base.org"
    priv_hex = ENV['TREASURY_PRIVATE_KEY'].to_s.strip.delete_prefix("0x")
    raise "TREASURY_PRIVATE_KEY not set" if priv_hex.empty?

    key    = build_ec_key(priv_hex)
    sender = derive_address(key)

    nonce     = rpc_call(rpc_url, "eth_getTransactionCount", [sender, "pending"]).to_i(16)
    gas_price = rpc_call(rpc_url, "eth_gasPrice", []).to_i(16) * 2

    asset = transfer.asset.to_s

    if asset == "eth"
      # Native ETH transfer
      amount_wei = (transfer.crypto_amount * 10**18).to_i
      gas_limit  = 21_000
      Rails.logger.info "TransferPayout: sender=#{sender} nonce=#{nonce} gas=#{gas_price} amount_wei=#{amount_wei} [ETH transfer=#{transfer.id}]"
      raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                  to: transfer.receiver_wallet_address, data: "", value: amount_wei, key: key)
    elsif asset == "wbtc"
      # ERC-20 WBTC (8 decimals)
      amount_units = (transfer.crypto_amount * 10**8).to_i
      calldata     = build_transfer_calldata(transfer.receiver_wallet_address, amount_units)
      gas_limit    = estimate_gas(rpc_url, sender, WBTC_ADDRESS, calldata)
      Rails.logger.info "TransferPayout: sender=#{sender} nonce=#{nonce} gas=#{gas_price} amount=#{amount_units} [WBTC transfer=#{transfer.id}]"
      raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                  to: WBTC_ADDRESS, data: calldata, key: key)
    else
      # ERC-20 USDC (6 decimals)
      amount_units = (transfer.crypto_amount * 10**6).to_i
      calldata     = build_transfer_calldata(transfer.receiver_wallet_address, amount_units)
      gas_limit    = estimate_gas(rpc_url, sender, USDC_ADDRESS, calldata)
      Rails.logger.info "TransferPayout: sender=#{sender} nonce=#{nonce} gas=#{gas_price} amount=#{amount_units} [USDC transfer=#{transfer.id}]"
      raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                  to: USDC_ADDRESS, data: calldata, key: key)
    end

    tx_hash = rpc_call(rpc_url, "eth_sendRawTransaction", ["0x#{raw_tx}"])
    raise "RPC returned no tx hash" if tx_hash.blank?

    transfer.update!(
      status: :sent,
      blockchain_tx_hash: tx_hash
    )
    Rails.logger.info "TransferPayout: sent #{transfer.crypto_amount} #{transfer.asset_label} → #{transfer.receiver_wallet_address}. Hash: #{tx_hash} [transfer=#{transfer.id}]"

    # Schedule on-chain confirmation polling
    TransferConfirmationWorker.perform_in(15.seconds, transfer.id)
  end

  # ── Crypto helpers (mirrored from CryptoTransferWorker) ─────────────────

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
    pub_bytes = key.public_key.to_octet_string(:uncompressed)[1..]
    addr_hash = Digest::Keccak.digest(pub_bytes, 256)
    "0x" + addr_hash.unpack1('H*')[-40..]
  end

  def build_transfer_calldata(to_address, amount_units)
    addr_padded   = to_address.delete_prefix("0x").downcase.rjust(64, '0')
    amount_padded = amount_units.to_s(16).rjust(64, '0')
    TRANSFER_SELECTOR + addr_padded + amount_padded
  end

  def build_and_sign_tx(nonce:, gas_price:, gas_limit:, to:, data:, key:, value: 0)
    to_bytes   = [to.delete_prefix("0x")].pack('H*')
    data_bytes = data.empty? ? "".b : [data].pack('H*')

    unsigned = rlp_encode([
      encode_int(nonce), encode_int(gas_price), encode_int(gas_limit),
      to_bytes, encode_int(value), data_bytes,
      encode_int(CHAIN_ID), "".b, "".b
    ])

    hash  = Digest::Keccak.digest(unsigned, 256)
    r, s, v = sign_hash(hash, key)

    rlp_encode([
      encode_int(nonce), encode_int(gas_price), encode_int(gas_limit),
      to_bytes, encode_int(value), data_bytes,
      encode_int(v), encode_int(r), encode_int(s)
    ]).unpack1('H*')
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

    [r, s, v]
  end

  def recovery_id(hash_bytes, r, s, key)
    expected = key.public_key.to_octet_string(:uncompressed)[1..].unpack1('H*')
    [0, 1, 2, 3].each do |i|
      candidate = recover_public_key(hash_bytes, r, s, i)
      return i if candidate == expected
    end
    raise "ECDSA recovery failed: could not recover public key from signature."
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
    [hex].pack('H*').b
  end

  # ── JSON-RPC ────────────────────────────────────────────────────────────

  def rpc_call(url, method, params)
    conn = Faraday.new(url: url) { |f| f.adapter Faraday.default_adapter }
    resp = conn.post do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
    end
    body = JSON.parse(resp.body)
    raise "RPC error (#{method}): #{body['error']}" if body['error']
    body['result']
  end

  def estimate_gas(url, from, to, data)
    result = rpc_call(url, "eth_estimateGas", [{
      from: from, to: to, data: "0x#{data}", value: "0x0"
    }])
    (result.to_i(16) * 1.2).to_i
  end

  # ── Email notifications ─────────────────────────────────────────────────

  def notify_sender_completed(transfer)
    TransferMailer.with(transfer_id: transfer.id).sender_completed.deliver_later
  rescue => e
    Rails.logger.error "Transfer sender_completed email failed [transfer=#{transfer.id}]: #{e.message}"
  end

  def notify_receiver_completed(transfer)
    return if transfer.receiver_email.blank?

    TransferMailer.with(transfer_id: transfer.id).receiver_completed.deliver_later
  rescue => e
    Rails.logger.error "Transfer receiver_completed email failed [transfer=#{transfer.id}]: #{e.message}"
  end

  def notify_sender_failed(transfer)
    TransferMailer.with(transfer_id: transfer.id).sender_failed.deliver_later
  rescue => e
    Rails.logger.error "Transfer sender_failed email failed [transfer=#{transfer.id}]: #{e.message}"
  end
end

# frozen_string_literal: true

require "sidekiq"
require "faraday"

class TransferPayoutWorker
  include Sidekiq::Job

  # Base Mainnet
  CHAIN_ID     = 8453
  USD_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  WBTC_ADDRESS = ENV.fetch("WBTC_CONTRACT_ADDRESS", "0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b")
  TRANSFER_SELECTOR = "a9059cbb"

  def perform(transfer_id)
    transfer = Transfer.find(transfer_id)

    # Only process funded or claimed transfers
    return unless transfer.funded? || transfer.claimed?

    # Acquire DB lock to prevent duplicate payouts from concurrent retries
    transfer.with_lock do
      # Re-check status under lock — another worker may have completed it
      transfer.reload
      return unless transfer.funded? || transfer.claimed?

      dispatch_payout(transfer)
    end
  end

  private

  def dispatch_payout(transfer)
    # Bank transfers are admin-processed — skip automatic payout
    if transfer.bank_transfer?
      Rails.logger.info "TransferPayout: bank transfer=#{transfer.id} skipped (admin-processed)"
      return
    end

    if transfer.htg_transfer?
      process_htg_payout(transfer)
    elsif transfer.usd_wallet_transfer?
      process_usd_wallet_payout(transfer)
    elsif transfer.stock_wallet_transfer?
      process_stock_wallet_payout(transfer)
    else
      process_crypto_payout(transfer)
    end

  rescue => e
    Rails.logger.error "TransferPayout error [transfer=#{transfer.id}]: #{e.message}"
    begin
      if transfer && !transfer.completed?
        mark_failed_and_refund!(transfer, e.message)
      end
    rescue => refund_err
      Rails.logger.error "TransferPayout: refund also failed [transfer=#{transfer.id}]: #{refund_err.message}"
    end
    raise
  end

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
        award_invite_points_if_first!(receiver_user, transfer)
        Rails.logger.info "TransferPayout: #{transfer.net_amount} HTG credited to wallet of user=#{receiver_user.id} [transfer=#{transfer.id}]"
        return
      rescue => e
        # If receiver was found by cashtag, don't fall through to MonCash —
        # MonCash phone on the transfer is likely the sender's, not the receiver's.
        if transfer.receiver_cashtag.present?
          mark_failed_and_refund!(transfer, "Pa ka kredite pòtfèy #{transfer.receiver_cashtag}: #{e.message}")
          Rails.logger.error "TransferPayout: wallet credit failed for cashtag user=#{receiver_user.id}, NOT falling to MonCash [transfer=#{transfer.id}]: #{e.message}"
          return
        end
        Rails.logger.warn "TransferPayout: wallet credit failed for user=#{receiver_user.id}, falling back to MonCash [transfer=#{transfer.id}]: #{e.message}"
        # Fall through to MonCash payout only for phone-based transfers
      end
    end

    # ── MonCash payout (existing path) ──

    # Need receiver phone to send MonCash
    if transfer.receiver_phone.blank?
      Rails.logger.info "TransferPayout: transfer=#{transfer.id} waiting for receiver to claim (no phone)"
      return
    end

    # Pre-check: verify MonCash treasury has enough HTG
    begin
      prefunded = MoncashService.prefunded_balance_info
      if prefunded[:success]
        treasury_bal = prefunded[:balance].to_f
        if treasury_bal < transfer.net_amount.to_f
          mark_failed_and_refund!(transfer, "Trezò MonCash pa gen ase likidite (#{treasury_bal.to_i} HTG disponib, bezwen #{transfer.net_amount.to_i} HTG)")
          Rails.logger.error "TransferPayout: treasury insufficient [transfer=#{transfer.id}]: #{treasury_bal} < #{transfer.net_amount}"
          return
        end
      else
        mark_failed_and_refund!(transfer, "Pa ka verifye trezò MonCash: #{prefunded[:error]}")
        Rails.logger.error "TransferPayout: treasury check failed [transfer=#{transfer.id}]: #{prefunded[:error]}"
        return
      end
    rescue => e
      mark_failed_and_refund!(transfer, "Erè trezò MonCash: #{e.message}")
      Rails.logger.error "TransferPayout: treasury check error [transfer=#{transfer.id}]: #{e.message}"
      return
    end

    payout_reference = "zellus-transfer-#{transfer.id}"

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
      "Zèllus Transfer"
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

  # ── Find receiver by cashtag, email, phone, or payment method ──
  def find_receiver_user(transfer)
    # 1. Cashtag (highest priority)
    if transfer.receiver_cashtag.present?
      user = User.find_by("LOWER(cashtag) = ?", transfer.receiver_cashtag.downcase)
      return user if user && user.id != transfer.user_id
    end

    # 2. Email
    if transfer.receiver_email.present?
      user = User.find_by(email: transfer.receiver_email)
      return user if user && user.id != transfer.user_id
    end

    # 3. Phone on User model
    if transfer.receiver_phone.present?
      user = User.find_by(phone_number: transfer.receiver_phone)
      return user if user && user.id != transfer.user_id
    end

    # 4. Phone via payment_methods (existing fallback)
    if transfer.receiver_phone.present?
      pm = PaymentMethod.where(active: true, category: "mobile_wallet", provider: "moncash")
                        .where(account_number: transfer.receiver_phone)
                        .first
      return pm.user if pm && pm.user_id != transfer.user_id
    end

    nil
  end

  # ── Award invite points on first completed transfer to receiver ──
  def award_invite_points_if_first!(receiver_user, transfer)
    return unless receiver_user.invited_by.present?

    completed_count = Transfer.where(status: :completed).where(
      "receiver_email = :email OR receiver_cashtag = :cashtag OR receiver_phone = :phone",
      email: receiver_user.email,
      cashtag: receiver_user.cashtag,
      phone: receiver_user.phone_number
    ).count

    if completed_count == 1 # This is the first completed transfer
      receiver_user.award_invite_points!
      Rails.logger.info "TransferPayout: +#{User::INVITE_POINTS} PrioNet points awarded to inviter user=#{receiver_user.invited_by_id} [transfer=#{transfer.id}]"
    end
  rescue => e
    Rails.logger.error "TransferPayout: invite points failed [transfer=#{transfer.id}]: #{e.message}"
  end

  # ── Mark transfer failed and refund sender's wallet if wallet-funded ──
  def mark_failed_and_refund!(transfer, reason)
    # Use update_columns to bypass model validations — the transfer may
    # have invalid data (e.g. missing wallet address) that blocks update!
    transfer.update_columns(status: "failed", failure_reason: reason.to_s.truncate(500))
    notify_sender_failed(transfer)

    if transfer.wallet_funded?
      begin
        sender_wallet = transfer.user.wallet
        if sender_wallet
          if transfer.usd_wallet_transfer? || transfer.usd_address_transfer?
            usd_amount = transfer.crypto_amount || transfer.net_amount
            WalletService.new(sender_wallet).refund!(
              amount: usd_amount,
              asset: "usd",
              reference: transfer,
              reason: "Transfè USD echwe — ranbousman otomatik"
            )
            Rails.logger.info "TransferPayout: refunded #{usd_amount} USD to sender wallet [transfer=#{transfer.id}]"
          elsif transfer.stock_wallet_transfer?
            stock_asset  = transfer.asset.to_s
            stock_amount = transfer.crypto_amount || transfer.net_amount
            WalletService.new(sender_wallet).refund!(
              amount: stock_amount,
              asset: stock_asset,
              reference: transfer,
              reason: "Transfè #{stock_asset.upcase} echwe — ranbousman otomatik"
            )
            Rails.logger.info "TransferPayout: refunded #{stock_amount} #{stock_asset.upcase} to sender wallet [transfer=#{transfer.id}]"
          else
            WalletService.new(sender_wallet).refund!(
              amount: transfer.amount,
              reference: transfer,
              reason: "Transfè echwe — ranbousman otomatik"
            )
            Rails.logger.info "TransferPayout: refunded #{transfer.amount} HTG to sender wallet [transfer=#{transfer.id}]"
          end
        end
      rescue => e
        Rails.logger.error "TransferPayout: wallet refund failed [transfer=#{transfer.id}]: #{e.message}"
      end
    end
  end

  # ── USD Wallet-to-Wallet (via $zellustag) ───────────────────────────────

  def process_usd_wallet_payout(transfer)
    receiver_user = find_receiver_user(transfer)

    unless receiver_user.present?
      mark_failed_and_refund!(transfer, "Resevè $#{transfer.receiver_cashtag} pa jwenn")
      Rails.logger.error "TransferPayout: USD wallet receiver not found [transfer=#{transfer.id}]"
      return
    end

    begin
      receiver_wallet = receiver_user.ensure_wallet!
      usd_amount = transfer.crypto_amount || transfer.net_amount

      WalletService.new(receiver_wallet).transfer_in!(
        amount: usd_amount,
        transfer: transfer,
        sender_user: transfer.user,
        asset: "usd"
      )

      transfer.update!(
        status: :completed,
        completed_at: Time.current,
        payout_method: "wallet"
      )

      notify_sender_completed(transfer)
      notify_receiver_completed(transfer)
      award_invite_points_if_first!(receiver_user, transfer)

      Rails.logger.info "TransferPayout: #{usd_amount} USD credited to wallet of user=#{receiver_user.id} [transfer=#{transfer.id}]"
    rescue => e
      Rails.logger.error "TransferPayout: USD wallet credit failed [transfer=#{transfer.id}]: #{e.message}"
      mark_failed_and_refund!(transfer, "Echèk kredi pòtfèy USD: #{e.message}")
    end
  end

  # ── Stock Wallet-to-Wallet (via $zellustag) ─────────────────────────────

  def process_stock_wallet_payout(transfer)
    receiver_user = find_receiver_user(transfer)

    unless receiver_user.present?
      mark_failed_and_refund!(transfer, "Resevè $#{transfer.receiver_cashtag} pa jwenn")
      Rails.logger.error "TransferPayout: stock wallet receiver not found [transfer=#{transfer.id}]"
      return
    end

    begin
      receiver_wallet = receiver_user.ensure_wallet!
      stock_asset  = transfer.asset.to_s
      stock_amount = transfer.crypto_amount || transfer.net_amount

      WalletService.new(receiver_wallet).transfer_in!(
        amount: stock_amount,
        transfer: transfer,
        sender_user: transfer.user,
        asset: stock_asset
      )

      transfer.update!(
        status: :completed,
        completed_at: Time.current,
        payout_method: "wallet"
      )

      notify_sender_completed(transfer)
      notify_receiver_completed(transfer)
      award_invite_points_if_first!(receiver_user, transfer)

      Rails.logger.info "TransferPayout: #{stock_amount} #{stock_asset.upcase} credited to wallet of user=#{receiver_user.id} [transfer=#{transfer.id}]"
    rescue => e
      Rails.logger.error "TransferPayout: stock wallet credit failed [transfer=#{transfer.id}]: #{e.message}"
      mark_failed_and_refund!(transfer, "Echèk kredi pòtfèy #{stock_asset.upcase}: #{e.message}")
    end
  end

  # ── Crypto: Send USD/ETH/WBTC ──────────────────────────────────────────
  #
  # Routes through Circle when available, falls back to self-hosted treasury.
  # Circle internal transfers (wallet→wallet) are instant and gas-free.

  def process_crypto_payout(transfer)
    if CryptoProvider.circle? && transfer.asset.to_s == "usd"
      process_crypto_payout_circle(transfer)
    else
      process_crypto_payout_self_hosted(transfer)
    end
  end

  def process_crypto_payout_circle(transfer)
    sender = transfer.user
    unless sender.circle_wallet_id.present?
      Rails.logger.info "TransferPayout: sender user=#{sender.id} has no Circle wallet, falling back to self-hosted [transfer=#{transfer.id}]"
      return process_crypto_payout_self_hosted(transfer)
    end

    amount = transfer.crypto_amount || transfer.net_amount
    unless amount.present? && amount > 0
      transfer.update!(status: :failed, failure_reason: "Pa gen montan kripto")
      notify_sender_failed(transfer)
      return
    end

    idempotency_key = "transfer-#{transfer.id}"

    # Speed hack: if receiver also has a Circle wallet, use internal transfer
    # (instant, zero gas, no blockchain hit)
    receiver_user = find_receiver_user(transfer)
    if receiver_user&.circle_wallet_id.present?
      result = CircleService.internal_transfer(
        from_wallet_id:  sender.circle_wallet_id,
        to_wallet_id:    receiver_user.circle_wallet_id,
        amount:          amount,
        idempotency_key: idempotency_key
      )
    else
      # External send — must have a valid address
      begin
        EthAddressValidator.validate!(transfer.receiver_wallet_address)
      rescue EthAddressValidator::InvalidAddressError => e
        transfer.update!(status: :failed, failure_reason: e.message)
        notify_sender_failed(transfer)
        return
      end

      result = CircleService.send_usd(
        from_wallet_id:  sender.circle_wallet_id,
        to_address:      transfer.receiver_wallet_address,
        amount:          amount,
        idempotency_key: idempotency_key
      )
    end

    if result[:success]
      transfer.update!(
        status: :sent,
        blockchain_tx_hash: result[:transaction_id]
      )
      Rails.logger.info "TransferPayout: Circle USD send ok [transfer=#{transfer.id}] tx=#{result[:transaction_id]}"
      TransferConfirmationWorker.perform_in(15.seconds, transfer.id)
    else
      Rails.logger.error "TransferPayout: Circle send failed [transfer=#{transfer.id}]: #{result[:error]}"
      # Fall back to self-hosted on Circle failure
      Rails.logger.info "TransferPayout: falling back to self-hosted [transfer=#{transfer.id}]"
      process_crypto_payout_self_hosted(transfer)
    end
  end

  def process_crypto_payout_self_hosted(transfer)
    require "digest/keccak"
    require "openssl"

    begin
      EthAddressValidator.validate!(transfer.receiver_wallet_address)
    rescue EthAddressValidator::InvalidAddressError => e
      Rails.logger.error "TransferPayout: invalid wallet address [transfer=#{transfer.id}]: #{e.message}"
      transfer.update!(status: :failed, failure_reason: e.message)
      notify_sender_failed(transfer)
      return
    end

    unless transfer.crypto_amount.present? && transfer.crypto_amount > 0
      Rails.logger.error "TransferPayout: no crypto amount [transfer=#{transfer.id}]"
      transfer.update!(status: :failed, failure_reason: "Pa gen montan kripto")
      notify_sender_failed(transfer)
      return
    end

    rpc_url  = ENV["BASE_RPC_URL"].presence || "https://mainnet.base.org"
    priv_hex = ENV["TREASURY_PRIVATE_KEY"].to_s.strip.delete_prefix("0x")
    raise "TREASURY_PRIVATE_KEY not set" if priv_hex.empty?

    key    = build_ec_key(priv_hex)
    sender = derive_address(key)

    TreasuryNonceLock.with_nonce(rpc_url, sender) do |nonce|
      gas_price = capped_gas_price(rpc_url)
      asset = transfer.asset.to_s

      if asset == "eth"
        amount_wei = (transfer.crypto_amount * 10**18).to_i
        gas_limit  = 21_000
        raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                    to: transfer.receiver_wallet_address, data: "", value: amount_wei, key: key)
      elsif asset == "wbtc"
        amount_units = (transfer.crypto_amount * 10**8).to_i
        calldata     = build_transfer_calldata(transfer.receiver_wallet_address, amount_units)
        gas_limit    = estimate_gas(rpc_url, sender, WBTC_ADDRESS, calldata)
        raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                    to: WBTC_ADDRESS, data: calldata, key: key)
      else
        amount_units = (transfer.crypto_amount * 10**6).to_i
        calldata     = build_transfer_calldata(transfer.receiver_wallet_address, amount_units)
        gas_limit    = estimate_gas(rpc_url, sender, USD_ADDRESS, calldata)
        raw_tx = build_and_sign_tx(nonce: nonce, gas_price: gas_price, gas_limit: gas_limit,
                                    to: USD_ADDRESS, data: calldata, key: key)
      end

      Rails.logger.info "TransferPayout: signing #{asset.upcase} tx [transfer=#{transfer.id}]"

      tx_hash = rpc_call(rpc_url, "eth_sendRawTransaction", [ "0x#{raw_tx}" ])
      raise "RPC returned no tx hash" if tx_hash.blank?

      transfer.update!(
        status: :sent,
        blockchain_tx_hash: tx_hash
      )
      Rails.logger.info "TransferPayout: broadcast ok [transfer=#{transfer.id}]"

      # Schedule on-chain confirmation polling
      TransferConfirmationWorker.perform_in(15.seconds, transfer.id)
    end
  end

  # ── Crypto helpers (mirrored from CryptoTransferWorker) ─────────────────

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

  # Retry signing up to 5 times — OpenSSL ECDSA uses a random nonce k,
  # so recovery_id may fail for one signature but succeed on the next.
  def sign_hash_with_retry(hash_bytes, key, max_attempts: 5)
    last_error = nil
    max_attempts.times do |attempt|
      begin
        return sign_hash(hash_bytes, key)
      rescue => e
        last_error = e
        Rails.logger.warn "TransferPayout: signing attempt #{attempt + 1} failed: #{e.message}, retrying..."
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

  MAX_GAS_PRICE = 500_000_000_000 # 500 gwei

  def capped_gas_price(rpc_url)
    base_price = rpc_call(rpc_url, "eth_gasPrice", []).to_i(16)
    [ base_price * 2, MAX_GAS_PRICE ].min
  end

  def estimate_gas(url, from, to, data)
    result = rpc_call(url, "eth_estimateGas", [ {
      from: from, to: to, data: "0x#{data}", value: "0x0"
    } ])
    (result.to_i(16) * 1.2).to_i
  end

  # ── Email & in-app notifications ────────────────────────────────────────

  def notify_sender_completed(transfer)
    TransferMailer.with(transfer_id: transfer.id).sender_completed.deliver_later
    NotificationService.transfer_completed(transfer)
    WebhookService.dispatch("transfer.completed", user: transfer.user, payload: webhook_transfer_payload(transfer))
  rescue => e
    Rails.logger.error "Transfer sender_completed notification failed [transfer=#{transfer.id}]: #{e.message}"
  end

  def notify_receiver_completed(transfer)
    # Play sound HERE — this runs when funds actually land in the wallet.
    # The controller's earlier broadcast was a silent preview (play_sound: false).
    NotificationService.transfer_received(transfer)

    receiver_user = find_receiver_user(transfer)
    WebhookService.dispatch("transfer.received", user: receiver_user, payload: webhook_transfer_payload(transfer)) if receiver_user

    return if transfer.receiver_email.blank?
    TransferMailer.with(transfer_id: transfer.id).receiver_completed.deliver_later
  rescue => e
    Rails.logger.error "Transfer receiver_completed notification failed [transfer=#{transfer.id}]: #{e.message}"
  end

  def notify_sender_failed(transfer)
    TransferMailer.with(transfer_id: transfer.id).sender_failed.deliver_later
    NotificationService.transfer_failed(transfer)
    WebhookService.dispatch("transfer.failed", user: transfer.user, payload: webhook_transfer_payload(transfer))
  rescue => e
    Rails.logger.error "Transfer sender_failed notification failed [transfer=#{transfer.id}]: #{e.message}"
  end

  def webhook_transfer_payload(transfer)
    {
      token: transfer.token,
      status: transfer.status,
      amount: transfer.amount.to_s,
      fee: transfer.fee.to_s,
      net_amount: transfer.net_amount.to_s,
      asset: transfer.asset,
      receiver: transfer.receiver_display,
      created_at: transfer.created_at.iso8601
    }
  end
end

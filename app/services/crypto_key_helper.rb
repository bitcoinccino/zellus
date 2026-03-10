# frozen_string_literal: true

# Shared helpers for secp256k1 key derivation and Ethereum address computation.
# Used by TransferPayoutWorker, TransferConfirmationWorker, UsdcDepositMonitorWorker,
# and WalletsController for treasury address display.
module CryptoKeyHelper
  extend self

  def build_ec_key(priv_hex)
    require 'openssl'

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
    require 'digest/keccak'

    pub_bytes = key.public_key.to_octet_string(:uncompressed)[1..]
    addr_hash = Digest::Keccak.digest(pub_bytes, 256)
    "0x" + addr_hash.unpack1('H*')[-40..]
  end

  # ── Per-user deterministic address derivation ──
  # Uses HMAC-SHA256(WALLET_MASTER_KEY, "user:<id>") as the private key seed.
  # No private keys stored in DB — re-derivable from master key + user_id.

  def derive_user_private_key(user_id)
    require 'openssl'

    master_key = ENV['WALLET_MASTER_KEY'].to_s.strip
    raise "WALLET_MASTER_KEY not set" if master_key.empty?

    hmac = OpenSSL::HMAC.digest('SHA256', master_key, "user:#{user_id}")
    hmac.unpack1('H*')
  end

  def derive_user_address(user_id)
    priv_hex = derive_user_private_key(user_id)
    key = build_ec_key(priv_hex)
    derive_address(key)
  rescue => e
    Rails.logger.error "CryptoKeyHelper: user address derivation failed for user=#{user_id}: #{e.message}" if defined?(Rails)
    nil
  end

  # Convenience: derive treasury address from ENV
  def treasury_address
    priv_hex = ENV['TREASURY_PRIVATE_KEY'].to_s.strip.delete_prefix("0x")
    return nil if priv_hex.empty?

    key = build_ec_key(priv_hex)
    derive_address(key)
  rescue => e
    Rails.logger.error "CryptoKeyHelper: treasury address derivation failed: #{e.message}" if defined?(Rails)
    nil
  end
end

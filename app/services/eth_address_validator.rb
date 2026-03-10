# frozen_string_literal: true

# Validates Ethereum (EVM) addresses before on-chain transactions.
#
# Usage:
#   EthAddressValidator.validate!("0x1234...")  # raises if invalid
#   EthAddressValidator.valid?("0x1234...")     # returns true/false
#
class EthAddressValidator
  PATTERN = /\A0x[0-9a-fA-F]{40}\z/

  # Known burn/dead addresses that should never receive funds
  BLOCKED_ADDRESSES = %w[
    0x0000000000000000000000000000000000000000
    0x000000000000000000000000000000000000dead
  ].map(&:downcase).freeze

  class InvalidAddressError < StandardError; end

  def self.validate!(address)
    raise InvalidAddressError, "Adrès wallet vid" if address.blank?
    raise InvalidAddressError, "Fòma adrès pa valid: #{address}" unless address.match?(PATTERN)
    raise InvalidAddressError, "Pa ka voye nan adrès sa a (burn address)" if BLOCKED_ADDRESSES.include?(address.downcase)

    # Check against treasury to prevent self-transfers
    treasury = CryptoKeyHelper.treasury_address
    if treasury.present? && address.downcase == treasury.downcase
      raise InvalidAddressError, "Pa ka voye nan adrès trezori a"
    end

    true
  end

  def self.valid?(address)
    validate!(address)
    true
  rescue InvalidAddressError
    false
  end
end

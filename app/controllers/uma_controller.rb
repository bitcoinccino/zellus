# frozen_string_literal: true

# UMA (Universal Money Address) protocol endpoints.
#
# These are public, unauthenticated endpoints that allow external wallets
# (Cash App, Coinbase, Revolut, etc.) to discover Zèllus users and send
# money to their $username@zellus.ht address.
#
# Spec: https://github.com/uma-universal-money-address/protocol/blob/main/umad-04-lnurlp.md
#
#   GET  /.well-known/lnurlp/:username       → user discovery
#   POST /.well-known/lnurlp/:username/payreq → payment request generation
#
class UmaController < ActionController::API
  # GET /.well-known/lnurlp/:username
  # User discovery — returns supported currencies, min/max amounts, callback URL.
  def lnurlp
    username = params[:username].to_s.downcase

    user = User.find_by("LOWER(cashtag) = ?", username)

    unless user && user.uma_enabled?
      return render json: { status: "ERROR", reason: "User not found or UMA disabled" }, status: :not_found
    end

    unless LightsparkConfig.enabled?
      return render json: { status: "ERROR", reason: "UMA receiving not available" }, status: :service_unavailable
    end

    callback_url = "#{request.base_url}/.well-known/lnurlp/#{username}/payreq"

    render json: {
      callback:       callback_url,
      maxSendable:    1_000_000_000_000, # 1M sats in msats
      minSendable:    1_000,             # 1 sat in msats
      metadata:       lnurlp_metadata(user),
      tag:            "payRequest",
      currencies:     supported_currencies,
      umaVersion:     "1.0",
      receiverKYCStatus: user.bonid_verified? ? 1 : 0
    }
  end

  # POST /.well-known/lnurlp/:username/payreq
  # Generates a payment request with converted amount.
  def payreq
    username = params[:username].to_s.downcase

    user = User.find_by("LOWER(cashtag) = ?", username)

    unless user && user.uma_enabled?
      return render json: { status: "ERROR", reason: "User not found or UMA disabled" }, status: :not_found
    end

    unless LightsparkConfig.enabled?
      return render json: { status: "ERROR", reason: "UMA receiving not available" }, status: :service_unavailable
    end

    amount_msats     = params[:amount].to_i # amount in msats from sender
    sending_currency = (params[:currency] || "SAT").upcase

    if amount_msats <= 0
      return render json: { status: "ERROR", reason: "Invalid amount" }, status: :bad_request
    end

    # Convert msats → USD → HTG
    btc_usd   = RateService.btc_usd_rate.to_d
    amount_btc = BigDecimal(amount_msats.to_s) / BigDecimal("100_000_000_000") # msats → BTC
    amount_usd = (amount_btc * btc_usd).round(2)

    sell_rate  = RateService.sell_rate.to_d
    amount_htg = (amount_usd * sell_rate).round(2)

    # Remittance fee
    fee_htg = FeeService.remittance_fee(amount_htg)
    net_htg = amount_htg - fee_htg

    # Build payreq response with conversion info
    render json: {
      routes:              [],
      pr:                  "", # Lightning invoice — Grid handles this
      disposable:          false,
      successAction:       { tag: "message", message: "Peman voye bay $#{user.cashtag} sou Zèllus!" },
      converted: {
        amount:   net_htg.to_f,
        currency: "HTG",
        fee:      fee_htg.to_f,
        rate:     sell_rate.to_f
      },
      payeeData: {
        name:       user.bonid_full_name || user.display_name,
        identifier: user.uma_address
      }
    }
  end

  private

  def lnurlp_metadata(user)
    display_name = user.bonid_full_name || user.display_name
    [
      [ "text/plain",       "Peye #{display_name} sou Zèllus" ],
      [ "text/identifier",  user.uma_address ]
    ].to_json
  end

  def supported_currencies
    [
      {
        code:       "HTG",
        name:       "Goud Ayisyen",
        symbol:     "G",
        multiplier: RateService.sell_rate.to_f,
        decimals:   2
      },
      {
        code:       "USD",
        name:       "US Dollar",
        symbol:     "$",
        multiplier: 1.0,
        decimals:   2
      }
    ]
  end
end

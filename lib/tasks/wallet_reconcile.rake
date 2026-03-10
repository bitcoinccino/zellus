# frozen_string_literal: true

namespace :wallet do
  desc "Reconcile internal wallet balances with on-chain treasury holdings"
  task reconcile: :environment do
    require 'faraday'

    USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    WBTC_ADDRESS = "0x236aa50979D5f3De3Bd1Eeb40E81137F22ab794b" # wBTC on Base

    rpc_url  = ENV['BASE_RPC_URL'].presence || "https://mainnet.base.org"
    priv_hex = ENV['TREASURY_PRIVATE_KEY'].to_s.strip.delete_prefix("0x")

    if priv_hex.empty?
      puts "ERROR: TREASURY_PRIVATE_KEY not set"
      exit 1
    end

    # ── Derive treasury address ──
    require 'digest/keccak'
    require 'openssl'

    priv_hex = priv_hex.rjust(64, '0')
    priv_bn  = OpenSSL::BN.new(priv_hex, 16)
    group    = OpenSSL::PKey::EC::Group.new('secp256k1')
    pub_point = group.generator.mul(priv_bn)
    pub_bytes = pub_point.to_octet_string(:uncompressed)[1..]
    addr_hash = Digest::Keccak.digest(pub_bytes, 256)
    treasury_address = "0x" + addr_hash.unpack1('H*')[-40..]

    puts "=" * 60
    puts "WALLET RECONCILIATION"
    puts "=" * 60
    puts "Treasury address: #{treasury_address}"
    puts "RPC: #{rpc_url}"
    puts

    # ── Fetch on-chain balances ──
    def rpc_call(url, method, params)
      conn = Faraday.new { |f| f.adapter :net_http }
      resp = conn.post(url) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
      end
      JSON.parse(resp.body)["result"]
    end

    # ETH balance
    eth_raw = rpc_call(rpc_url, "eth_getBalance", [treasury_address, "latest"])
    treasury_eth = eth_raw.to_i(16).to_d / 10**18

    # USDC balance (6 decimals)
    usdc_calldata = "70a08231" + treasury_address.delete_prefix("0x").rjust(64, '0')
    usdc_raw = rpc_call(rpc_url, "eth_call", [{ to: USDC_ADDRESS, data: "0x#{usdc_calldata}" }, "latest"])
    treasury_usdc = usdc_raw.to_i(16).to_d / 10**6

    # wBTC balance (8 decimals)
    wbtc_calldata = "70a08231" + treasury_address.delete_prefix("0x").rjust(64, '0')
    wbtc_raw = rpc_call(rpc_url, "eth_call", [{ to: WBTC_ADDRESS, data: "0x#{wbtc_calldata}" }, "latest"])
    treasury_wbtc = wbtc_raw.to_i(16).to_d / 10**8

    puts "ON-CHAIN TREASURY BALANCES:"
    puts "  ETH:  #{treasury_eth}"
    puts "  USDC: #{treasury_usdc}"
    puts "  wBTC: #{treasury_wbtc}"
    puts

    # ── Sum all internal wallet balances ──
    total_internal_usdc = Wallet.sum(:usdc_balance)
    total_internal_eth  = Wallet.sum(:eth_balance)
    total_internal_wbtc = Wallet.sum(:wbtc_balance)

    puts "TOTAL INTERNAL BALANCES (all wallets):"
    puts "  ETH:  #{total_internal_eth}"
    puts "  USDC: #{total_internal_usdc}"
    puts "  wBTC: #{total_internal_wbtc}"
    puts

    # ── Calculate discrepancies ──
    diff_usdc = total_internal_usdc - treasury_usdc
    diff_eth  = total_internal_eth - treasury_eth
    diff_wbtc = total_internal_wbtc - treasury_wbtc

    puts "DISCREPANCY (internal - on-chain):"
    puts "  ETH:  #{diff_eth >= 0 ? '+' : ''}#{diff_eth}"
    puts "  USDC: #{diff_usdc >= 0 ? '+' : ''}#{diff_usdc}"
    puts "  wBTC: #{diff_wbtc >= 0 ? '+' : ''}#{diff_wbtc}"
    puts

    adjustments = []
    adjustments << { asset: "usdc", excess: diff_usdc, treasury: treasury_usdc } if diff_usdc > 0.001
    adjustments << { asset: "eth",  excess: diff_eth,  treasury: treasury_eth }  if diff_eth > 0.000001
    adjustments << { asset: "wbtc", excess: diff_wbtc, treasury: treasury_wbtc } if diff_wbtc > 0.00000001

    if adjustments.empty?
      puts "All balances are in sync. Nothing to do."
      exit 0
    end

    puts "WALLETS THAT NEED ADJUSTMENT:"
    adjustments.each do |adj|
      asset = adj[:asset]
      col = "#{asset}_balance"
      wallets_with_balance = Wallet.where("#{col} > 0").includes(:user)
      wallets_with_balance.each do |w|
        puts "  User ##{w.user_id} (#{w.user&.display_name}): #{w.send(col)} #{asset.upcase}"
      end
    end
    puts

    # ── Ask for confirmation ──
    puts "This will proportionally reduce each wallet's balance so the total"
    puts "matches the on-chain treasury. Adjustment ledger entries will be created."
    puts
    print "Proceed? (yes/no): "
    answer = $stdin.gets&.strip&.downcase
    unless answer == "yes"
      puts "Aborted."
      exit 0
    end

    # ── Apply adjustments ──
    adjustments.each do |adj|
      asset = adj[:asset]
      col = "#{asset}_balance"
      treasury_bal = adj[:treasury]
      total_internal = Wallet.sum(col.to_sym)

      next if total_internal <= 0

      # Proportional scaling: each wallet gets (their_balance / total_internal) * treasury_bal
      wallets_with_balance = Wallet.where("#{col} > 0").lock(true)

      ActiveRecord::Base.transaction do
        wallets_with_balance.each do |wallet|
          old_balance = wallet.send(col)
          new_balance = (old_balance / total_internal * treasury_bal).round(8)
          reduction = old_balance - new_balance

          next if reduction <= 0

          # Create adjustment ledger entry
          wallet.wallet_ledger_entries.create!(
            user: wallet.user,
            entry_type: "withdrawal",
            asset: asset,
            amount: reduction,
            balance_after: new_balance,
            description: "Rekonsilyasyon pòtfèy — ajisteman #{asset.upcase} pou matche ak trezori"
          )

          wallet.update!(col => new_balance)
          puts "  Adjusted User ##{wallet.user_id}: #{old_balance} -> #{new_balance} #{asset.upcase} (reduced #{reduction})"
        end
      end
    end

    puts
    puts "Reconciliation complete!"
    puts
    puts "NEW INTERNAL BALANCES:"
    puts "  USDC: #{Wallet.sum(:usdc_balance)}"
    puts "  ETH:  #{Wallet.sum(:eth_balance)}"
    puts "  wBTC: #{Wallet.sum(:wbtc_balance)}"
  end
end

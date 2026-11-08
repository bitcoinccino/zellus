# Re-settles past HTG-priced USD transfers in whole cents.
#
# Before 7623b8b a transfer typed in HTG and paid from USD moved e.g.
# 1.00369 USD for 136 HTG. This rewrites each such transfer to the amount it
# moves today (Transfer.asset_amount_from_htg), so the history shows exactly
# what moved and every balance equals the sum of its ledger lines:
#   - transfers.crypto_amount
#   - the transfer's ledger entries (amount + "Resevwa … USD" description)
#   - balance_after for every later USD entry of the affected wallets
#   - wallets.usd_balance
#
# Dry run by default; APPLY=1 writes, inside one DB transaction. Aborts if a
# wallet's ledger doesn't currently replay to its balance (nothing is changed).
#
#   bin/rails usd:dust_cleanup           # show the plan
#   bin/rails usd:dust_cleanup APPLY=1   # do it
namespace :usd do
  desc "Re-settle sub-cent HTG-priced USD transfers in whole cents (APPLY=1 to write)"
  task dust_cleanup: :environment do
    apply = ENV["APPLY"] == "1"
    credit = %w[deposit transfer_in refund conversion_in]
    debit  = %w[withdrawal transfer_out fee instant_fee conversion_out conversion_fee]
    fmt    = ->(v) { v.to_d.to_s("F") }

    transfers = Transfer.where(asset: "usd").where.not(crypto_amount: nil)
                        .select { |t| t.crypto_amount.round(2) != t.crypto_amount }
    if transfers.empty?
      puts "No sub-cent USD transfers. Nothing to do."
      next
    end

    new_amount = transfers.to_h { |t| [ t.id, Transfer.asset_amount_from_htg(t.amount, t.exchange_rate, "usd") ] }

    ActiveRecord::Base.transaction do
      transfers.each do |t|
        puts "Transfer ##{t.id} (#{t.status}): #{t.amount.to_d.to_s('F')} HTG @ #{t.exchange_rate} " \
             "#{fmt.(t.crypto_amount)} -> #{format('%.2f', new_amount[t.id])} USD"
        t.update_columns(crypto_amount: new_amount[t.id]) if apply
      end

      entries = WalletLedgerEntry.where(asset: "usd", reference_type: "Transfer", reference_id: transfers.map(&:id))
      wallet_ids = entries.distinct.pluck(:wallet_id)

      wallet_ids.each do |wid|
        wallet = Wallet.lock.find(wid)
        rows = WalletLedgerEntry.where(wallet_id: wid, asset: "usd").order(:created_at, :id).to_a
        first = rows.first
        sign  = ->(e) { credit.include?(e.entry_type) ? 1 : (debit.include?(e.entry_type) ? -1 : raise("unknown entry_type #{e.entry_type} on ##{e.id}")) }
        start = first.balance_after - sign.(first) * first.amount

        # Sanity: the current ledger must replay to the current balance.
        replay = rows.sum(start) { |e| sign.(e) * e.amount }
        if replay != wallet.usd_balance
          raise "Wallet ##{wid}: ledger replays to #{fmt.(replay)} but balance is #{fmt.(wallet.usd_balance)}. Aborting, nothing changed."
        end

        running = start
        rows.each do |e|
          amt = e.reference_type == "Transfer" && new_amount.key?(e.reference_id) ? new_amount[e.reference_id] : e.amount
          running += sign.(e) * amt
          raise "Wallet ##{wid}: balance would go negative at entry ##{e.id}. Aborting." if running.negative?
          next if amt == e.amount && running == e.balance_after

          desc = e.description.to_s.sub(fmt.(e.amount), format("%.2f", amt))
          if apply
            e.update_columns(amount: amt, balance_after: running, description: desc)
          end
        end

        owner = wallet.user&.cashtag || "?"
        puts "Wallet ##{wid} ($#{owner}): #{fmt.(wallet.usd_balance)} -> #{format('%.2f', running)} USD"
        wallet.update_columns(usd_balance: running) if apply
      end

      puts apply ? "Applied." : "Dry run only. Re-run with APPLY=1 to write."
    end
  end
end

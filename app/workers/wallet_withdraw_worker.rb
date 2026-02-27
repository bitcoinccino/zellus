# frozen_string_literal: true

class WalletWithdrawWorker
  include Sidekiq::Job

  # fee = 0 for standard withdrawals, > 0 for instant (so we refund the full amount on failure)
  def perform(user_id, amount, phone, fee = 0)
    user   = User.find(user_id)
    wallet = user.wallet
    return unless wallet

    refund_total = amount.to_d + fee.to_d
    reference    = "wallet-withdraw-#{user_id}-#{Time.now.to_i}"

    # 1. Verify MonCash receiver is active
    customer_check = MoncashService.customer_status(phone)
    unless customer_check[:success] && customer_check[:active]
      WalletService.new(wallet).refund!(
        amount: refund_total,
        reason: "Retrè echwe: Kont MonCash #{phone} pa aktif — ranbouse #{refund_total.to_i} HTG"
      )
      Rails.logger.error "WalletWithdraw: MonCash account #{phone} not active [user=#{user_id}]"
      return
    end

    # 2. Send to MonCash (only the withdrawal amount, not the fee)
    result = MoncashService.transfert(
      phone,
      amount.to_i,
      reference,
      "Priotelus Wallet Withdrawal"
    )

    if result[:success]
      # Update the most recent withdrawal ledger entry with MonCash tx id
      entry = wallet.wallet_ledger_entries.withdrawals.order(created_at: :desc).first
      entry&.update(moncash_transaction_id: result[:transaction_id])
      Rails.logger.info "WalletWithdraw: #{amount} HTG sent to #{phone} [user=#{user_id}, fee=#{fee}]"
    else
      # Ambiguous error: check if payout actually went through
      status_check = MoncashService.prefunded_transaction_status(reference)
      unless status_check[:success]
        WalletService.new(wallet).refund!(
          amount: refund_total,
          reason: "Retrè echwe: #{result[:error]} — ranbouse #{refund_total.to_i} HTG"
        )
        Rails.logger.error "WalletWithdraw: payout failed [user=#{user_id}]: #{result[:error]}"
      end
    end
  rescue => e
    Rails.logger.error "WalletWithdraw error [user=#{user_id}]: #{e.message}"
    begin
      user   = User.find(user_id)
      wallet = user.wallet
      if wallet
        refund_total = amount.to_d + fee.to_d
        WalletService.new(wallet).refund!(
          amount: refund_total,
          reason: "Retrè echwe: #{e.message.truncate(100)} — ranbouse #{refund_total.to_i} HTG"
        )
      end
    rescue => refund_error
      Rails.logger.error "WalletWithdraw refund failed [user=#{user_id}]: #{refund_error.message}"
    end
    raise
  end
end

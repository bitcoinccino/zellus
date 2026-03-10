# frozen_string_literal: true

class WalletWithdrawWorker
  include Sidekiq::Job

  # fee is subtracted from amount: payout = amount - fee
  # refund on failure = amount (the full amount debited from wallet)
  def perform(user_id, amount, phone, fee = 0)
    user   = User.find(user_id)
    wallet = user.wallet
    return unless wallet

    payout    = (amount.to_d - fee.to_d).to_i  # What user actually receives via MonCash
    refund_total = amount.to_d                  # Full amount to refund on failure (including fee)
    reference = "wallet-withdraw-#{user_id}-#{Time.now.to_i}"

    # 1. Verify MonCash receiver is active
    customer_check = MoncashService.customer_status(phone)
    unless customer_check[:success] && customer_check[:active]
      WalletService.new(wallet).refund!(
        amount: refund_total,
        reason: "Retrè echwe: Kont MonCash #{phone} pa aktif — ranbouse #{refund_total.to_i} HTG"
      )
      NotificationService.withdrawal_failed(user, refund_total, "Kont MonCash pa aktif")
      Rails.logger.error "WalletWithdraw: MonCash account #{phone} not active [user=#{user_id}]"
      return
    end

    # 2. Send payout to MonCash (amount minus fee)
    result = MoncashService.transfert(
      phone,
      payout,
      reference,
      "Zèllus Wallet Withdrawal"
    )

    if result[:success]
      entry = wallet.wallet_ledger_entries.withdrawals.order(created_at: :desc).first
      entry&.update(moncash_transaction_id: result[:transaction_id])
      NotificationService.withdrawal_sent(user, payout, "MonCash")
      Rails.logger.info "WalletWithdraw: #{payout} HTG sent to #{phone} [user=#{user_id}, fee=#{fee}]"
    else
      status_check = MoncashService.prefunded_transaction_status(reference)
      unless status_check[:success]
        WalletService.new(wallet).refund!(
          amount: refund_total,
          reason: "Retrè echwe: #{result[:error]} — ranbouse #{refund_total.to_i} HTG"
        )
        NotificationService.withdrawal_failed(user, refund_total, result[:error].to_s)
        Rails.logger.error "WalletWithdraw: payout failed [user=#{user_id}]: #{result[:error]}"
      end
    end
  rescue => e
    Rails.logger.error "WalletWithdraw error [user=#{user_id}]: #{e.message}"
    begin
      user   = User.find(user_id)
      wallet = user.wallet
      if wallet
        WalletService.new(wallet).refund!(
          amount: amount.to_d,
          reason: "Retrè echwe: #{e.message.truncate(100)} — ranbouse #{amount.to_i} HTG"
        )
        NotificationService.withdrawal_failed(user, amount.to_d, e.message.truncate(80))
      end
    rescue => refund_error
      Rails.logger.error "WalletWithdraw refund failed [user=#{user_id}]: #{refund_error.message}"
    end
    raise
  end
end

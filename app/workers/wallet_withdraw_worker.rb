# frozen_string_literal: true

class WalletWithdrawWorker
  include Sidekiq::Job

  # fee is subtracted from amount: payout = amount - fee
  # refund on failure = amount (the full amount debited from wallet)
  # source: "personal" or "biznis" — determines where refund goes on failure
  def perform(user_id, amount, phone, fee = 0, source = "personal")
    user   = User.find(user_id)
    wallet = user.wallet
    return unless wallet

    payout    = (amount.to_d - fee.to_d).to_i  # What user actually receives via MonCash
    refund_total = amount.to_d                  # Full amount to refund on failure (including fee)
    reference = "wallet-withdraw-#{user_id}-#{Time.now.to_i}"

    # 1. Verify MonCash receiver is active (skip on sandbox — sandbox doesn't support customer_status reliably)
    # TODO: Remove sandbox bypass when switching to MonCash production credentials.
    sandbox = MoncashService::BASE_URL.include?("sandbox")
    unless sandbox
      customer_check = MoncashService.customer_status(phone)
      unless customer_check[:success] && customer_check[:active]
        refund_withdrawal!(wallet, user, refund_total, source,
          "Retrè echwe: Kont MonCash #{phone} pa aktif — ranbouse #{refund_total.to_i} HTG")
        NotificationService.withdrawal_failed(user, refund_total, "Kont MonCash pa aktif")
        Rails.logger.error "WalletWithdraw: MonCash account #{phone} not active [user=#{user_id}]"
        return
      end
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
      WebhookService.dispatch("withdrawal.completed", user: user, payload: {
        amount: payout.to_s, asset: "htg", method: "moncash", phone: phone
      })
      Rails.logger.info "WalletWithdraw: #{payout} HTG sent to #{phone} [user=#{user_id}, fee=#{fee}]"
    else
      status_check = MoncashService.prefunded_transaction_status(reference)
      unless status_check[:success]
        friendly = friendly_moncash_error(result[:error])
        refund_withdrawal!(wallet, user, refund_total, source,
          "Retrè echwe: #{friendly}. Lajan ou ranbouse.")
        NotificationService.withdrawal_failed(user, refund_total, friendly)
        WebhookService.dispatch("withdrawal.failed", user: user, payload: {
          amount: refund_total.to_s, asset: "htg", method: "moncash", reason: friendly
        })
        Rails.logger.error "WalletWithdraw: payout failed [user=#{user_id}]: #{result[:error]}"
      end
    end
  rescue => e
    Rails.logger.error "WalletWithdraw error [user=#{user_id}]: #{e.message}"
    begin
      user   = User.find(user_id)
      wallet = user.wallet
      if wallet
        friendly_msg = "Erè teknik — tanpri eseye ankò pita"
        refund_withdrawal!(wallet, user, amount.to_d, source,
          "Retrè echwe: #{friendly_msg} — ranbouse #{amount.to_i} HTG")
        NotificationService.withdrawal_failed(user, amount.to_d, friendly_msg)
        Rails.logger.error "WalletWithdraw: raw error: #{e.message}"
      end
    rescue => refund_error
      Rails.logger.error "WalletWithdraw refund failed [user=#{user_id}]: #{refund_error.message}"
    end
    raise
  end

  private

  # Translate raw MonCash API errors to user-friendly Creole messages
  def friendly_moncash_error(raw_error)
    msg = raw_error.to_s

    case msg
    when /No short code/i, /short.*code.*not/i
      "Kont MonCash sa a pa konfigire pou resevwa peman"
    when /403|Forbidden/i
      "MonCash refize peman an"
    when /404|Not Found/i
      "Kont MonCash pa egziste"
    when /401|Unauthorized/i
      "Erè otantifikasyon ak MonCash"
    when /timeout|timed out/i
      "MonCash pran twòp tan pou reponn"
    when /insufficient|pa gen ase/i
      "Sistèm pa gen ase fon pou trete retrè a"
    when /invalid.*phone|phone.*invalid/i
      "Nimewo MonCash pa valid"
    when /500|503|502/, /server error/i
      "Sèvis MonCash pa disponib pou kounye a"
    else
      "Erè teknik ak MonCash — tanpri eseye ankò pita"
    end
  end

  def refund_withdrawal!(wallet, user, amount, source, reason)
    if source == "biznis" && user.business.present?
      # Refund back to business account
      user.business.with_lock do
        user.business.increment!(:total_received, amount)
      end
      Rails.logger.info "WalletWithdraw: refunded #{amount.to_i} HTG to business [user=#{user.id}]"
    else
      # Refund to personal wallet
      WalletService.new(wallet).refund!(amount: amount, reason: reason)
    end
  end
end

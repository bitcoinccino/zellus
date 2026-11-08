# frozen_string_literal: true

# Auto-debits wallet on due_date for users who opted in
# LoanAutoRepayWorker.perform_async(loan_id)
class LoanAutoRepayWorker
  include Sidekiq::Job

  ON_TIME_BONUS = 50 # PrioNet points for on-time repayment

  def perform(loan_id)
    loan = Transaction.find(loan_id)
    user = loan.user
    wallet = user.wallet

    return unless loan.loan_request? && loan.paid? # paid = approved/disbursed
    return unless user.auto_repay_enabled?
    return unless wallet.present?

    repay_amount = loan.loan_total_repayable || loan.fiat_amount

    # Check sufficient balance
    if wallet.htg_balance >= repay_amount
      begin
        # Withdraw from wallet
        WalletService.new(wallet).withdraw!(
          amount: repay_amount,
          instant: false
        )

        # Mark loan as completed
        loan.update!(status: :completed)

        # Award on-time bonus points
        current_score = user.credit_score || 0
        new_score = [ current_score + ON_TIME_BONUS, User::MAX_CREDIT_SCORE ].min
        user.update!(credit_score: new_score)

        # Send success email
        LoanMailer.with(loan_id: loan.id, success: true)
                  .auto_repay_processed
                  .deliver_later

        Rails.logger.info "LoanAutoRepay: Success loan=#{loan.id} user=#{user.id} amount=#{repay_amount}"
      rescue WalletService::InsufficientFundsError => e
        notify_failure(loan, user)
        Rails.logger.error "LoanAutoRepay: Insufficient funds loan=#{loan.id}: #{e.message}"
      rescue => e
        notify_failure(loan, user)
        Rails.logger.error "LoanAutoRepay: Error loan=#{loan.id}: #{e.message}"
        raise
      end
    else
      notify_failure(loan, user)
      Rails.logger.warn "LoanAutoRepay: Insufficient balance loan=#{loan.id} user=#{user.id} (need #{repay_amount}, have #{wallet.htg_balance})"
    end
  end

  private

  def notify_failure(loan, user)
    LoanMailer.with(loan_id: loan.id, success: false)
              .auto_repay_processed
              .deliver_later
  rescue => e
    Rails.logger.error "LoanAutoRepay: Failed to send failure email loan=#{loan.id}: #{e.message}"
  end
end

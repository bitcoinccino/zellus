# frozen_string_literal: true

# Run daily via Sidekiq cron (e.g., every day at 9AM)
# LoanReminderWorker.perform_async
class LoanReminderWorker
  include Sidekiq::Job

  REMINDER_DAYS    = [7, 3, 0].freeze   # days before due_date to send reminders
  LATE_PENALTY_PER_DAY = 15              # PrioNet points deducted per day late
  LATE_PENALTY_CAP     = 300             # max total penalty from lateness
  ON_TIME_BONUS        = 50              # bonus points for paying on time

  def perform
    process_reminders
    process_late_penalties
    process_auto_repay
  end

  private

  # ── Send reminders at 7, 3, 0 days before due_date ──
  def process_reminders
    Transaction.where(transaction_type: "loan_request", status: :paid) # "paid" = approved/disbursed
               .where.not(loan_due_date: nil)
               .find_each do |loan|
      days_left = (loan.loan_due_date - Date.current).to_i

      if REMINDER_DAYS.include?(days_left)
        send_reminder(loan, days_left)
      end
    end
  end

  # ── Penalize overdue loans: -15 PrioNet pwen per day late ──
  def process_late_penalties
    Transaction.where(transaction_type: "loan_request", status: :paid)
               .where("loan_due_date < ?", Date.current)
               .find_each do |loan|
      days_overdue = (Date.current - loan.loan_due_date).to_i
      user = loan.user

      # Only penalize once per day (check if already penalized today)
      # We use a simple approach: deduct daily, capped at LATE_PENALTY_CAP total
      total_possible_penalty = [days_overdue * LATE_PENALTY_PER_DAY, LATE_PENALTY_CAP].min
      current_score = user.credit_score || 0

      # Calculate what penalty has already been applied (track via failure_reason tag)
      already_penalized = loan.failure_reason.to_s.scan(/LATE_PENALTY:(\d+)/).flatten.first.to_i
      new_penalty = total_possible_penalty - already_penalized

      if new_penalty > 0 && current_score > 0
        deduction = [new_penalty, current_score].min # don't go below 0
        user.update!(credit_score: current_score - deduction)
        loan.update!(failure_reason: "Pionye Loan Request | LATE_PENALTY:#{total_possible_penalty}")
        Rails.logger.info "LoanReminder: Penalized user=#{user.id} loan=#{loan.id} -#{deduction} pwen (#{days_overdue} jou an reta)"

        # Send overdue reminder (once per day while overdue)
        send_reminder(loan, -days_overdue)
      end
    end
  end

  # ── Auto-repay for users who opted in ──
  def process_auto_repay
    Transaction.where(transaction_type: "loan_request", status: :paid)
               .where(loan_due_date: Date.current)
               .includes(:user)
               .find_each do |loan|
      user = loan.user
      next unless user.auto_repay_enabled?

      LoanAutoRepayWorker.perform_async(loan.id)
    end
  end

  def send_reminder(loan, days_left)
    LoanMailer.with(loan_id: loan.id, days_left: days_left)
              .repayment_reminder
              .deliver_later
  rescue => e
    Rails.logger.error "LoanReminder: Failed to send reminder for loan=#{loan.id}: #{e.message}"
  end
end

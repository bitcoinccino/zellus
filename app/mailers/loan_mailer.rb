class LoanMailer < ApplicationMailer
  # ── Loan Request Submitted ──
  def request_submitted
    load_loan
    mail(to: @user.email, subject: "Zèllus: Demann Prè Anrejistre (##{@loan.id})")
  end

  # ── Loan Approved & Disbursed ──
  def approved
    load_loan
    mail(to: @user.email, subject: "Zèllus: Prè Ou Apwouve! (##{@loan.id})")
  end

  # ── Loan Rejected ──
  def rejected
    load_loan
    mail(to: @user.email, subject: "Zèllus: Demann Prè Refize (##{@loan.id})")
  end

  # ── Repayment Reminder ──
  def repayment_reminder
    load_loan
    @days_left = params[:days_left] || 0
    mail(to: @user.email, subject: reminder_subject)
  end

  # ── Repayment Confirmed ──
  def repayment_confirmed
    load_loan
    mail(to: @user.email, subject: "Zèllus: Ranbousman Prè Konfime (##{@loan.id})")
  end

  # ── Auto-Repay Processed ──
  def auto_repay_processed
    load_loan
    @success = params[:success]
    subject = @success ? "Zèllus: Ranbousman Otomatik Fè (##{@loan.id})" : "Zèllus: Ranbousman Otomatik Echwe (##{@loan.id})"
    mail(to: @user.email, subject: subject)
  end

  private

  def load_loan
    @loan = Transaction.includes(:user).find(params[:loan_id])
    @user = @loan.user
    @brand_name = "Zèllus Bank"
  end

  def format_htg(value)
    "HTG #{format('%.0f', value.to_f)}"
  end

  def reminder_subject
    case @days_left
    when 7 then "Zèllus: Rapèl — Prè dwe nan 1 semèn (##{@loan.id})"
    when 3 then "Zèllus: Ijans — Prè dwe nan 3 jou (##{@loan.id})"
    when 0 then "Zèllus: Dat Limit Jodi a! (##{@loan.id})"
    else        "Zèllus: Prè An Reta! (##{@loan.id})"
    end
  end
end

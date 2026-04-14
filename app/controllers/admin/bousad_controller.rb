class Admin::BousadController < Admin::BaseController
  include ActionView::Helpers::NumberHelper

  # GET /admin/bousad/applicants
  def applicants
    @loan_requests = Transaction.includes(user: [:business, { avatar_attachment: :blob }])
                                .where(transaction_type: :loan_request, status: :pending)
                                .order(created_at: :desc)
    @usd_htg_rate = begin; RateService.usd_htg_rate; rescue; 135.50; end
  end

  # POST /admin/bousad/:id/approve
  def approve
    @transaction = Transaction.find_by!(token: params[:id])

    unless @transaction.loan_request? && @transaction.pending?
      redirect_to admin_bousad_applicants_path, alert: "Demann prè sa a pa valid oswa deja trete."
      return
    end

    begin
      prefunded_info = MoncashService.prefunded_balance_info
      if prefunded_info[:success]
        current_balance = prefunded_info[:balance].to_f
        if current_balance < @transaction.fiat_amount.to_f
          redirect_to admin_bousad_applicants_path, alert: "Likidite Ensifizan: Bezwen #{number_with_delimiter(@transaction.fiat_amount.to_i)} HTG, men sèlman #{number_with_delimiter(current_balance.to_i)} HTG disponib nan MonCash."
          return
        end
      else
        redirect_to admin_bousad_applicants_path, alert: "Erè MonCash API: Pa ka verifye balans. Peman anile."
        return
      end
    rescue => e
      Rails.logger.error "Bousad Liquidity Check Error: #{e.message}"
      redirect_to admin_bousad_applicants_path, alert: "Erè sistèm pandan verifikasyon likidite. Eseye ankò."
      return
    end

    @transaction.update!(status: :crypto_sent, failure_reason: nil)
    SellTransferWorker.perform_async(@transaction.id)
    redirect_to admin_bousad_applicants_path, notice: "Prè apwouve. Peman MonCash #{number_with_delimiter(@transaction.fiat_amount.to_i)} HTG an kou pou #{@transaction.user.display_name}."
  end

  # POST /admin/bousad/:id/reject
  def reject
    @transaction = Transaction.find_by!(token: params[:id])

    unless @transaction.loan_request? && @transaction.pending?
      redirect_to admin_bousad_applicants_path, alert: "Demann prè sa a pa valid oswa deja trete."
      return
    end

    reason = params[:reason].to_s.strip.presence || "Demann rejte pa administratè"
    @transaction.update!(status: :failed, failure_reason: reason)
    redirect_to admin_bousad_applicants_path, notice: "Demann prè #{@transaction.user.display_name} rejte."
  end

  # GET /admin/bousad/analytics
  def analytics
    @usd_htg_rate = begin; RateService.usd_htg_rate; rescue; 135.50; end

    loans = Transaction.where(transaction_type: :loan_request)
    @total_loans = loans.count
    @approved_loans = loans.where(status: [:crypto_sent, :completed]).count
    @pending_loans = loans.where(status: :pending).count
    @rejected_loans = loans.where(status: :failed).count
    @total_disbursed = loans.where(status: [:crypto_sent, :completed]).sum(:fiat_amount)
    @total_disbursed_usd = @usd_htg_rate > 0 ? (@total_disbursed / @usd_htg_rate).round(2) : 0
  end

  # GET /admin/bousad/activity
  def activity
    loans = Transaction.includes(user: [:business, { avatar_attachment: :blob }])
                       .where(transaction_type: :loan_request)
                       .order(created_at: :desc)

    # Filter by status
    if params[:status].present? && params[:status] != "tout"
      loans = loans.where(status: params[:status])
    end

    # Search
    if params[:q].present?
      q = params[:q].strip
      loans = loans.joins(:user).where(
        "users.cashtag ILIKE :q OR users.email ILIKE :q OR transactions.token ILIKE :q",
        q: "%#{q}%"
      )
    end

    @loans = loans.limit(50)
    @usd_htg_rate = begin; RateService.usd_htg_rate; rescue; 135.50; end
  end
end

class LoansController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_pionye_status

  def new
    @loan_limit = current_user.loan_limit
  end

  def create
    amount = params[:amount].to_f

    # 1. Safety Check: Ensure they aren't over their rank limit
    if amount > current_user.loan_limit || amount <= 0
      return redirect_to new_loan_path, alert: "Montan sa a depase limit ou."
    end

    # 2. Validate repayment term
    term = params[:repayment_term_weeks].to_i
    unless Transaction::REPAYMENT_TERMS.key?(term)
      return redirect_to new_loan_path, alert: "Tanpri chwazi yon tèm ranbousman valid."
    end

    # 3. Create the Loan Transaction with all fields
    @loan = current_user.transactions.create!(
      transaction_type: "loan_request",
      status: :pending,
      fiat_amount: amount,
      loan_purpose: params[:loan_purpose],
      repayment_term_weeks: term,
      collateral_description: params[:collateral_description].presence,
      moncash_phone: params[:moncash_phone] || current_user.payment_methods.moncash.first&.account_number,
      failure_reason: "Pionye Loan Request"
    )

    # Send confirmation email
    LoanMailer.with(loan_id: @loan.id).request_submitted.deliver_later

    redirect_to transaction_path(@loan), notice: "Demann prè ou anrejistre! Yon admin ap revize li."
  end

  # Repay from Wallet (instant debit)
  def repay_wallet
    @loan = current_user.transactions.loan_request.find_by!(token: params[:id])
    wallet = current_user.wallet

    unless wallet.present? && wallet.htg_balance >= @loan.loan_total_repayable
      return redirect_to transaction_path(@loan), alert: "Balans pòtfèy ou pa sifi pou ranbousman."
    end

    WalletService.new(wallet).withdraw!(
      amount: @loan.loan_total_repayable,
      instant: false
    )

    @loan.update!(status: :completed)

    # Award on-time bonus or skip if late
    unless @loan.loan_overdue?
      current_score = current_user.credit_score || 0
      new_score = [current_score + LoanReminderWorker::ON_TIME_BONUS, User::MAX_CREDIT_SCORE].min
      current_user.update!(credit_score: new_score)
    end

    LoanMailer.with(loan_id: @loan.id).repayment_confirmed.deliver_later
    redirect_to transaction_path(@loan), notice: "Ranbousman konplete! Mèsi."
  rescue WalletService::InsufficientFundsError
    redirect_to transaction_path(@loan), alert: "Balans pòtfèy ou pa sifi."
  end

  # Repayment Logic (MonCash or USDC)
  def repay
    @loan = current_user.transactions.loan_request.find_by!(token: params[:id])
    asset = params[:asset] || "htg"

    # Use loan_total_repayable (includes interest) instead of flat 3% fee
    total_htg = @loan.loan_total_repayable || (@loan.fiat_amount * 1.03)

    if asset == "htg"
      # MonCash Path
      @payment_request = PaymentRequest.create!(
        user: current_user,
        amount: total_htg,
        asset: "htg",
        note: "Loan Repay ##{@loan.id}",
        receiver_account_number: ENV['MONCASH_MERCHANT_PHONE']
      )
      redirect_to public_payment_request_path(@payment_request.token)
      
    elsif asset == "usd"
      # USD Path (Diaspora Friendly)
      buy_rate = RateService.buy_rate rescue 135.0
      usd_amount = (total_htg / buy_rate).round(6)

      @repayment_tx = current_user.transactions.create!(
        transaction_type: "sell", # User 'sells' USD to bank to clear debt
        status: :pending,
        fiat_amount: total_htg,
        crypto_amount: usd_amount,
        failure_reason: "REPAYMENT_LOAN_#{@loan.id}" # Critical tag for the Worker
      )
      redirect_to transaction_path(@repayment_tx), notice: "Tanpri voye #{usd_amount} USD pou n dechaje dèt ou a."
    end
  end

  private

  def ensure_pionye_status
    # Tier Gate: Must be Malfini or Folkon
    unless current_user.loan_limit > 0
      redirect_to root_path, alert: "Ou bezwen nivo Malfini pou debloke prè Pionye."
    end
  end
end

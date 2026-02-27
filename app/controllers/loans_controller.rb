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

    # 2. Create the Loan Transaction
    @loan = current_user.transactions.create!(
      transaction_type: "loan_request",
      status: :pending, # Admin must approve this in the dashboard
      fiat_amount: amount,
      moncash_phone: params[:moncash_phone] || current_user.payment_methods.moncash.first&.account_number,
      failure_reason: "Pionye Loan Request"
    )

    redirect_to transactions_path, notice: "Prè ou a soumèt! Yon admin ap verifye sa kounye a."
  end

  # Repayment Logic (MonCash or USDC)
  def repay
    @loan = current_user.transactions.loan_request.find(params[:id])
    asset = params[:asset] || "htg"
    
    # 3% Service Fee
    fee_htg = @loan.fiat_amount * 0.03
    total_htg = @loan.fiat_amount + fee_htg

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
      
    elsif asset == "usdc"
      # USDC Path (Diaspora Friendly)
      buy_rate = RateService.buy_rate rescue 135.0
      usdc_amount = (total_htg / buy_rate).round(6)
      
      @repayment_tx = current_user.transactions.create!(
        transaction_type: "sell", # User 'sells' USDC to bank to clear debt
        status: :pending,
        fiat_amount: total_htg,
        crypto_amount: usdc_amount,
        failure_reason: "REPAYMENT_LOAN_#{@loan.id}" # Critical tag for the Worker
      )
      redirect_to transaction_path(@repayment_tx), notice: "Tanpri voye #{usdc_amount} USDC pou n dechaje dèt ou a."
    end
  end

  private

  def ensure_pionye_status
    # Tier Gate: Must be Malfini or Fokon
    unless current_user.loan_limit > 0
      redirect_to root_path, alert: "Ou bezwen nivo Malfini pou debloke prè Pionye."
    end
  end
end

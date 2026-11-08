class MoncashWebhooksController < ApplicationController
  # Skip CSRF because MonCash doesn't have your authenticity token
  skip_before_action :verify_authenticity_token

  def create
    # 1. MonCash sends the 'transactionId' in the body
    moncash_id = params[:transactionId]

    # 2. Find the transaction in your database
    transaction = Transaction.find_by(moncash_transaction_id: moncash_id)

    if transaction && transaction.pending?
      # 3. Security: Call MonCash API to verify this payment is REAL
      # We pass the transaction object to the service for verification
      verification_data = MoncashService.verify_payment(moncash_id)

      if verification_data
        process_successful_payment(transaction, verification_data)
        render json: { status: "success" }, status: :ok
      else
        render json: { error: "Payment verification failed" }, status: :unauthorized
      end
    else
      render json: { error: "Transaction not found or already processed" }, status: :not_found
    end
  end

  private

  def process_successful_payment(transaction, verification_data)
    # 4. Update the status to 'paid'
    transaction.update!(status: :paid)

    # 5. Handle Repayment Logic (Check the note from MonCash)
    note = verification_data[:note] || ""

    if note.include?("Repayment for Loan")
      handle_loan_repayment(transaction, note)
    else
      # 6. TRIGGER THE RAMP: Regular crypto purchase
      CryptoTransferWorker.perform_async(transaction.id)
    end
  end

  def handle_loan_repayment(transaction, note)
    # Extract ID using regex (handles #123 format)
    match = note.match(/#(\d+)/)
    return unless match

    loan_id = match[1]
    loan = Transaction.find_by(id: loan_id)

    if loan
      # 1. Close the loan
      loan.update!(status: :completed)

      # 2. BIG BOOST: +50 points for paying back debt!
      transaction.user.increment!(:credit_score, 50)
    end
  end
end

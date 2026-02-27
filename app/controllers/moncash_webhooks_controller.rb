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
      if MoncashService.verify_payment(moncash_id)
        
        # 4. Update the status to 'paid'
        transaction.update!(status: :paid)

        # 5. TRIGGER THE RAMP: Send crypto to their Robinhood Wallet
        CryptoTransferWorker.perform_async(transaction.id)

        render json: { status: 'success' }, status: :ok
      else
        render json: { error: 'Payment verification failed' }, status: :unauthorized
      end
    else
      render json: { error: 'Transaction not found' }, status: :not_found
    end
  end
end

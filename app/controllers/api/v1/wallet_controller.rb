module Api
  module V1
    class WalletController < BaseController
      before_action -> { api_rate_limit!(limit: 60) }

      # GET /api/v1/wallet
      def show
        require_scope!("balance:read")
        return if performed?

        wallet = current_user.wallet

        unless wallet
          return render json: { error: "Pòtfèy pa egziste." }, status: :not_found
        end

        response = {
          success: true,
          wallet: {
            htg_balance: wallet.htg_balance.to_s,
            usd_balance: wallet.usd_balance.to_s,
            status: wallet.status
          }
        }

        # Include business balances if user has a business
        business = current_user.business
        if business
          response[:business] = {
            name: business.name,
            htg_balance: business.total_received.to_s,
            usd_balance: business.usd_balance.to_s
          }
        end

        render json: response
      end
    end
  end
end

module Api
  module V1
    class WithdrawalsController < BaseController
      before_action -> { api_rate_limit!(limit: 10) }

      WITHDRAW_MIN_HTG = 100
      WITHDRAW_MAX_HTG = 50_000
      USD_WITHDRAW_MIN = BigDecimal("1")
      USD_WITHDRAW_MAX = BigDecimal("500")

      # POST /api/v1/withdrawals
      def create
        require_scope!("withdraw:create")
        return if performed?

        amount = BigDecimal(params[:amount].to_s)
        asset  = params[:asset].to_s.downcase.presence || "htg"
        method = params[:method].to_s.downcase
        pin    = params[:pin].to_s.strip

        unless %w[htg usd].include?(asset)
          return render_error("Aktif pa valid. Itilize 'htg' oswa 'usd'.", status: :unprocessable_entity)
        end

        # PIN verification
        unless current_user.transfer_pin_set?
          return render_error("Ou dwe kreye yon PIN transfè anvan.", status: :unprocessable_entity)
        end

        unless current_user.verify_transfer_pin(pin)
          return render_error("PIN pa kòrèk.", status: :unauthorized)
        end

        wallet = current_user.ensure_wallet!

        case method
        when "moncash"
          handle_moncash_withdrawal(wallet, amount, asset)
        when "bank"
          handle_bank_withdrawal(wallet, amount, asset)
        when "crypto"
          handle_crypto_withdrawal(wallet, amount, asset)
        else
          render_error("Metòd pa valid. Itilize 'moncash', 'bank', oswa 'crypto'.", status: :unprocessable_entity)
        end
      end

      private

      def handle_moncash_withdrawal(wallet, amount, asset)
        unless asset == "htg"
          return render_error("MonCash disponib sèlman pou HTG.", status: :unprocessable_entity)
        end

        phone = params[:phone].to_s.gsub(/[^\d]/, "")
        unless phone.match?(/\A509\d{8}\z/)
          return render_error("Tanpri antre yon nimewo MonCash valid (509 + 8 chif).", status: :unprocessable_entity)
        end

        if amount < WITHDRAW_MIN_HTG || amount > WITHDRAW_MAX_HTG
          return render_error("Montan retrè dwe ant #{WITHDRAW_MIN_HTG} ak #{WITHDRAW_MAX_HTG} HTG.", status: :unprocessable_entity)
        end

        fee = WalletService.calculate_instant_fee(amount)
        payout = amount - fee
        reference = "WD-#{SecureRandom.alphanumeric(8)}"

        begin
          WalletService.new(wallet).withdraw!(amount: amount, instant: true)
          WalletWithdrawWorker.perform_async(current_user.id, amount.to_f, phone, fee.to_f, "personal")

          render json: {
            success: true,
            withdrawal: {
              reference: reference,
              amount: amount.to_s,
              fee: fee.to_s,
              payout: payout.to_s,
              asset: "htg",
              method: "moncash",
              status: "processing"
            }
          }, status: :created
        rescue WalletService::InsufficientFundsError
          render_error("Balans pa sifi.", status: :unprocessable_entity)
        rescue WalletService::FrozenAccountError
          render_error("Pòtfèy ou jele. Tanpri kontakte sipò.", status: :forbidden)
        end
      end

      def handle_bank_withdrawal(wallet, amount, asset)
        unless asset == "htg"
          return render_error("Retrè bank disponib sèlman pou HTG.", status: :unprocessable_entity)
        end

        bank_account = params[:bank_account].to_s.strip
        account_holder = params[:account_holder].to_s.strip

        if bank_account.blank?
          return render_error("Nimewo kont bank obligatwa.", status: :unprocessable_entity)
        end

        min = BankWithdrawal::MIN_AMOUNT rescue 500
        max = BankWithdrawal::MAX_AMOUNT rescue 500_000
        if amount < min || amount > max
          return render_error("Montan retrè bank dwe ant #{min} ak #{max} HTG.", status: :unprocessable_entity)
        end

        fee = WalletService.calculate_bank_fee(amount)
        payout = amount - fee
        reference = "WD-#{SecureRandom.alphanumeric(8)}"

        begin
          entry = WalletService.new(wallet).withdraw_bank!(amount: amount, fee: fee)

          BankWithdrawal.create!(
            user: current_user,
            wallet: wallet,
            wallet_ledger_entry: entry,
            amount: amount,
            bank_name: "UNIBANK",
            bank_account_number: bank_account,
            account_holder_name: account_holder.presence
          )

          render json: {
            success: true,
            withdrawal: {
              reference: reference,
              amount: amount.to_s,
              fee: fee.to_s,
              payout: payout.to_s,
              asset: "htg",
              method: "bank",
              status: "processing"
            }
          }, status: :created
        rescue WalletService::InsufficientFundsError
          render_error("Balans pa sifi.", status: :unprocessable_entity)
        rescue WalletService::FrozenAccountError
          render_error("Pòtfèy ou jele. Tanpri kontakte sipò.", status: :forbidden)
        end
      end

      def handle_crypto_withdrawal(wallet, amount, asset)
        unless asset == "usd"
          return render_error("Retrè crypto disponib sèlman pou USD.", status: :unprocessable_entity)
        end

        wallet_address = params[:wallet_address].to_s.strip
        unless wallet_address.match?(/\A0x[0-9a-fA-F]{40}\z/)
          return render_error("Tanpri antre yon adrès Base valid (0x…).", status: :unprocessable_entity)
        end

        if amount < USD_WITHDRAW_MIN || amount > USD_WITHDRAW_MAX
          return render_error("Montan retrè USD dwe ant #{USD_WITHDRAW_MIN} ak #{USD_WITHDRAW_MAX} USD.", status: :unprocessable_entity)
        end

        reference = "WD-#{SecureRandom.alphanumeric(8)}"

        begin
          WalletService.new(wallet).withdraw!(amount: amount, asset: "usd")
          WalletUsdWithdrawWorker.perform_async(current_user.id, amount.to_f, wallet_address)

          render json: {
            success: true,
            withdrawal: {
              reference: reference,
              amount: amount.to_s,
              fee: "0",
              payout: amount.to_s,
              asset: "usd",
              method: "crypto",
              status: "processing"
            }
          }, status: :created
        rescue WalletService::InsufficientFundsError
          render_error("Balans USD pa sifi.", status: :unprocessable_entity)
        rescue WalletService::FrozenAccountError
          render_error("Pòtfèy ou jele. Tanpri kontakte sipò.", status: :forbidden)
        end
      end
    end
  end
end

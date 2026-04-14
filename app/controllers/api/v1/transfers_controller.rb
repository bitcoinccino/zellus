module Api
  module V1
    class TransfersController < BaseController
      before_action -> { api_rate_limit!(limit: 10) }, only: [:create]
      before_action -> { api_rate_limit!(limit: 60) }, only: [:show]

      # POST /api/v1/transfers
      def create
        require_scope!("transfer:create")
        return if performed?

        # Validate required params
        receiver = params[:receiver].to_s.strip
        amount   = params[:amount].to_f
        asset    = params[:asset].to_s.downcase.presence || "htg"
        note     = params[:note].to_s.strip.presence
        pin      = params[:pin].to_s.strip

        unless %w[htg usd].include?(asset)
          return render_error("Aktif pa valid. Itilize 'htg' oswa 'usd'.", status: :unprocessable_entity)
        end

        if receiver.blank?
          return render_error("Resevwa obligatwa ($cashtag, telefòn, oswa imèl).", status: :unprocessable_entity)
        end

        if amount <= 0
          return render_error("Montan dwe plis pase 0.", status: :unprocessable_entity)
        end

        # PIN verification
        unless current_user.transfer_pin_set?
          return render_error("Ou dwe kreye yon PIN transfè anvan ou voye lajan.", status: :unprocessable_entity)
        end

        unless current_user.verify_transfer_pin(pin)
          return render_error("PIN pa kòrèk.", status: :unauthorized)
        end

        # Build transfer
        transfer = current_user.transfers.new(
          amount: amount,
          asset: asset,
          note: note
        )

        # Resolve receiver
        resolve_api_receiver(transfer, receiver, asset)

        # Per-transaction limits (HTG only)
        if asset == "htg"
          if amount < Transfer::SEND_MIN_HTG
            return render_error("Montan minimòm se #{Transfer::SEND_MIN_HTG} HTG.", status: :unprocessable_entity)
          end
          if amount > Transfer::SEND_MAX_HTG
            return render_error("Montan maksimòm se #{Transfer::SEND_MAX_HTG} HTG pa tranzaksyon.", status: :unprocessable_entity)
          end
        end

        # Daily limit check
        remaining = current_user.daily_transfer_remaining
        if amount > remaining
          limit = current_user.daily_transfer_limit
          return render json: {
            error: "Ou depase limit jounalye ou (#{limit.to_i} HTG/jou). Ou ka voye #{remaining.to_i} HTG ankò jodi a.",
            daily_limit: limit.to_s,
            daily_remaining: remaining.to_s
          }, status: :unprocessable_entity
        end

        unless transfer.save
          return render_error(transfer.errors.full_messages.join(". "), status: :unprocessable_entity)
        end

        # BonID consent check
        if BonIdService.consent_required?(transfer)
          unless current_user.bonid_verified?
            transfer.update!(status: :failed, failure_reason: "BonID pa verifye")
            return render_error("Pou pwoteje kont ou, montan sa a mande yon verifikasyon BonID.", status: :unprocessable_entity)
          end

          consent_result = BonIdService.request_consent(transfer)

          if consent_result[:success]
            transfer.update!(status: :awaiting_consent)

            BonidConsentRequest.create!(
              user: current_user,
              transfer: transfer,
              consent_token: consent_result[:consent_token],
              bonid: current_user.bonid,
              reference_id: "ZEL-transfer-#{transfer.token}",
              amount: transfer.amount,
              transaction_type: "p2p_transfer",
              expires_at: consent_result[:expires_at]
            )

            return render json: {
              success: true,
              transfer: serialize_transfer(transfer).merge(
                consent: {
                  status: "awaiting_consent",
                  expires_at: consent_result[:expires_at]&.iso8601,
                  message: "Tanpri apwouve transfè sa a nan BonID ou."
                }
              )
            }, status: :accepted
          else
            transfer.update!(status: :failed, failure_reason: "BonID consent endiponib")
            return render_error("Nou pa t kapab kontakte BonID. Tanpri eseye ankò.", status: :service_unavailable)
          end
        end

        # Fund from wallet
        wallet = current_user.ensure_wallet!

        begin
          WalletService.new(wallet).transfer_out!(
            amount: transfer.amount,
            fee: transfer.fee,
            transfer: transfer,
            asset: asset
          )

          transfer.update!(
            status: :funded,
            funded_at: Time.current,
            funding_source: "wallet",
            expires_at: 72.hours.from_now
          )

          TransferPayoutWorker.perform_async(transfer.id)

          render json: { success: true, transfer: serialize_transfer(transfer) }, status: :created
        rescue WalletService::InsufficientFundsError
          transfer.update!(status: :failed, failure_reason: "Balans pa sifi")
          render_error("Balans pa sifi.", status: :unprocessable_entity)
        rescue WalletService::FrozenAccountError
          transfer.update!(status: :failed, failure_reason: "Pòtfèy jele")
          render_error("Pòtfèy ou jele. Tanpri kontakte sipò.", status: :forbidden)
        end
      end

      # GET /api/v1/transfers/:token
      def show
        require_scope!("transactions:read")
        return if performed?

        transfer = current_user.transfers.find_by(token: params[:token])

        unless transfer
          return render_error("Transfè pa jwenn.", status: :not_found)
        end

        render json: { success: true, transfer: serialize_transfer(transfer) }
      end

      private

      def resolve_api_receiver(transfer, receiver, asset)
        clean = receiver.delete_prefix("$").strip

        # $cashtag
        if clean.match?(/\A[a-zA-Z0-9]{5,20}\z/)
          transfer.receiver_cashtag = clean.downcase
          found = User.find_by("LOWER(cashtag) = ?", clean.downcase)
          if found
            transfer.receiver_email = found.email if asset == "htg"
            transfer.receiver_name = found.display_name if transfer.receiver_name.blank?
            transfer.payout_method = "wallet"
          end
        # Phone (509XXXXXXXX)
        elsif clean.match?(/\A509\d{8}\z/) && asset == "htg"
          transfer.receiver_phone = clean
        # Email
        elsif clean.match?(URI::MailTo::EMAIL_REGEXP) && asset == "htg"
          transfer.receiver_email = clean
        else
          transfer.receiver_cashtag = clean.downcase if clean.length >= 5
        end
      end

      def serialize_transfer(transfer)
        {
          token: transfer.token,
          status: transfer.status,
          amount: transfer.amount.to_s,
          fee: transfer.fee.to_s,
          net_amount: transfer.net_amount.to_s,
          asset: transfer.asset,
          receiver: transfer.receiver_display,
          note: transfer.note,
          created_at: transfer.created_at.iso8601
        }
      end
    end
  end
end

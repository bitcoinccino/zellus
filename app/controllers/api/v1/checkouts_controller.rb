module Api
  module V1
    class CheckoutsController < BaseController
      before_action -> { api_rate_limit!(limit: 10) }, only: [:create, :refund]
      before_action -> { api_rate_limit!(limit: 60) }, only: [:show]

      # POST /api/v1/checkouts
      def create
        require_scope!("checkout:create")
        return if performed?

        receiver_cashtag = params[:receiver_cashtag].to_s.delete_prefix("$").strip.downcase
        amount           = params[:amount].to_f
        currency         = params[:currency].to_s.downcase.presence || "htg"
        description      = params[:description].to_s.strip.presence
        success_url      = params[:success_url].to_s.strip
        cancel_url       = params[:cancel_url].to_s.strip.presence
        metadata         = params[:metadata].is_a?(ActionController::Parameters) ? params[:metadata].to_unsafe_h : {}

        unless %w[htg usd].include?(currency)
          return render_error("Lajan pa valid. Itilize 'htg' oswa 'usd'.", status: :unprocessable_entity)
        end

        if amount <= 0
          return render_error("Montan dwe plis pase 0.", status: :unprocessable_entity)
        end

        if success_url.blank?
          return render_error("success_url obligatwa.", status: :unprocessable_entity)
        end

        if receiver_cashtag.blank?
          return render_error("receiver_cashtag obligatwa.", status: :unprocessable_entity)
        end

        receiver = User.find_by("LOWER(cashtag) = ?", receiver_cashtag)
        unless receiver
          return render_error("Cashtag '$#{receiver_cashtag}' pa egziste.", status: :unprocessable_entity)
        end

        checkout = CheckoutSession.new(
          oauth_client: current_token&.oauth_client,
          amount: amount,
          currency: currency,
          description: description,
          metadata: metadata,
          success_url: success_url,
          cancel_url: cancel_url,
          receiver_cashtag: receiver_cashtag,
          expires_at: 1.hour.from_now
        )

        unless checkout.save
          return render_error(checkout.errors.full_messages.join(". "), status: :unprocessable_entity)
        end

        render json: {
          success: true,
          checkout: serialize_checkout(checkout)
        }, status: :created
      end

      # GET /api/v1/checkouts/:token
      def show
        checkout = CheckoutSession.find_by(token: params[:token])
        unless checkout
          return render_error("Checkout pa jwenn.", status: :not_found)
        end

        checkout.mark_expired_if_needed!

        render json: {
          success: true,
          checkout: serialize_checkout(checkout)
        }
      end

      # POST /api/v1/checkouts/:token/refund
      def refund
        require_scope!("checkout:create")
        return if performed?

        checkout = CheckoutSession.find_by(token: params[:token])
        unless checkout
          return render_error("Checkout pa jwenn.", status: :not_found)
        end

        unless checkout.completed?
          return render_error("Sèlman checkout ki konplete ka ranbouse. Estati aktyèl: #{checkout.status}.", status: :unprocessable_entity)
        end

        transfer = checkout.transfer
        unless transfer
          return render_error("Transfè asosye pa jwenn.", status: :unprocessable_entity)
        end

        receiver = checkout.receiver_user
        payer = checkout.payer

        unless receiver && payer
          return render_error("Pa ka idantifye resevè oswa peyè.", status: :unprocessable_entity)
        end

        receiver_wallet = receiver.wallet
        payer_wallet = payer.wallet

        unless receiver_wallet && payer_wallet
          return render_error("Pòtfèy resevè oswa peyè pa jwenn.", status: :unprocessable_entity)
        end

        amount = checkout.amount
        asset = checkout.currency

        begin
          ActiveRecord::Base.transaction do
            WalletService.new(receiver_wallet).transfer_out!(
              amount: amount, fee: 0, transfer: transfer, asset: asset
            )

            WalletService.new(payer_wallet).refund!(
              amount: amount, asset: asset, reference: transfer,
              reason: "Ranbousman checkout ##{checkout.token}"
            )

            transfer.update!(status: :refunded)
            checkout.update!(status: :refunded, refunded_at: Time.current)
          end
        rescue WalletService::InsufficientFundsError
          return render_error("Resevè pa gen ase balans pou ranbousman.", status: :unprocessable_entity)
        end

        WebhookService.dispatch(
          "checkout.refunded",
          user: payer,
          payload: {
            checkout_token: checkout.token,
            transfer_token: transfer.token,
            amount: amount.to_s,
            currency: asset,
            receiver_cashtag: "$#{checkout.receiver_cashtag}",
            payer_cashtag: payer.cashtag ? "$#{payer.cashtag}" : nil,
            metadata: checkout.metadata
          }
        )

        render json: {
          success: true,
          checkout: serialize_checkout(checkout)
        }
      end

      private

      def serialize_checkout(checkout)
        result = {
          token: checkout.token,
          checkout_url: Rails.application.routes.url_helpers.checkout_pay_url(checkout.token, host: request.host_with_port, protocol: request.protocol),
          status: checkout.status,
          amount: checkout.amount.to_s,
          currency: checkout.currency,
          description: checkout.description,
          receiver_cashtag: "$#{checkout.receiver_cashtag}",
          metadata: checkout.metadata,
          expires_at: checkout.expires_at&.iso8601,
          created_at: checkout.created_at.iso8601
        }

        if checkout.completed? || checkout.refunded?
          result[:completed_at] = checkout.completed_at&.iso8601
          result[:transfer_token] = checkout.transfer&.token
          result[:payer_cashtag] = checkout.payer&.cashtag ? "$#{checkout.payer.cashtag}" : nil
        end

        if checkout.refunded?
          result[:refunded_at] = checkout.refunded_at&.iso8601
        end

        result
      end
    end
  end
end

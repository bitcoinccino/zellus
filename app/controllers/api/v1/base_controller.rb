module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate!
      before_action :check_idempotency_key, if: -> { request.post? }
      after_action :store_idempotency_response, if: -> { request.post? }
      after_action :set_granted_scopes_header

      private

      # Authenticate via API key or OAuth Bearer token
      def authenticate!
        @current_token = nil
        @current_user = nil
        @auth_method = nil

        auth_header = request.headers["Authorization"].to_s

        if auth_header.start_with?("Bearer ")
          token_string = auth_header.delete_prefix("Bearer ").strip
          @current_token = OauthToken.active
                                      .includes(:user, :oauth_client)
                                      .find_by(access_token: token_string)

          if @current_token
            @current_user = @current_token.user
            @auth_method = :oauth
          else
            render json: { error: "Token envalid oswa ekspire." }, status: :unauthorized
            nil
          end
        elsif request.headers["X-Partner-Api-Key"].present?
          api_key = request.headers["X-Partner-Api-Key"].to_s.strip
          if api_key == ENV["BONID_API_KEY"]
            @auth_method = :api_key
          else
            render json: { error: "Kle API envalid." }, status: :unauthorized
            nil
          end
        else
          render json: { error: "Otantifikasyon obligatwa. Itilize Bearer token oswa X-Partner-Api-Key." }, status: :unauthorized
        end
      end

      def current_user
        @current_user
      end

      def current_token
        @current_token
      end

      def oauth_auth?
        @auth_method == :oauth
      end

      def api_key_auth?
        @auth_method == :api_key
      end

      # Check if the current token has a specific scope
      def has_scope?(scope)
        return true if api_key_auth? # Full access with API key
        return false unless current_token

        current_token.granted_scopes.include?(scope.to_s)
      end

      def require_scope!(scope)
        unless has_scope?(scope)
          render json: { error: "Scope '#{scope}' obligatwa men pa akòde." }, status: :forbidden
        end
      end

      def set_granted_scopes_header
        return unless oauth_auth? && current_token

        response.headers["X-BonID-Granted-Scopes"] = current_token.granted_scopes.join(" ")
      end

      def render_error(message, status: :bad_request)
        render json: { error: message }, status: status
      end

      # ── Idempotency key support ──

      def check_idempotency_key
        key = request.headers["X-Idempotency-Key"].to_s.strip
        return if key.blank?
        return unless current_user

        @idempotency_record = ApiIdempotencyKey.find_by(
          user_id: current_user.id,
          idempotency_key: key,
          request_path: request.path
        )

        if @idempotency_record
          if @idempotency_record.response_body.present?
            # Replay cached response
            render json: @idempotency_record.response_body,
                   status: @idempotency_record.response_status,
                   content_type: "application/json"
          elsif @idempotency_record.locked_at.present? && @idempotency_record.locked_at > 60.seconds.ago
            # Another request is in progress
            render json: { error: "Demann sa a ap trete deja. Tanpri rete tann." }, status: :conflict
          else
            # Stale lock — reclaim it
            @idempotency_record.update!(locked_at: Time.current, response_body: nil, response_status: nil)
          end
        else
          @idempotency_record = ApiIdempotencyKey.create!(
            user: current_user,
            idempotency_key: key,
            request_path: request.path,
            locked_at: Time.current
          )
        end
      rescue ActiveRecord::RecordNotUnique
        # Race condition: another request created it first
        @idempotency_record = ApiIdempotencyKey.find_by!(
          user_id: current_user.id,
          idempotency_key: key,
          request_path: request.path
        )
        if @idempotency_record.response_body.present?
          render json: @idempotency_record.response_body,
                 status: @idempotency_record.response_status,
                 content_type: "application/json"
        else
          render json: { error: "Demann sa a ap trete deja. Tanpri rete tann." }, status: :conflict
        end
      end

      def store_idempotency_response
        return unless @idempotency_record

        @idempotency_record.update!(
          response_status: response.status,
          response_body: response.body,
          locked_at: nil
        )
      end

      # Per-token rate limiting using Rails.cache
      def api_rate_limit!(limit: 60, period: 1.minute)
        key = "api_rate:#{current_token&.id || request.remote_ip}:#{request.path}"
        count = Rails.cache.increment(key, 1, expires_in: period)
        if count && count > limit
          render json: { error: "Twòp demann. Limite: #{limit} pa minit." }, status: :too_many_requests
        end
      end
    end
  end
end

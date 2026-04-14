module Api
  module V1
    class IdentityController < BaseController
      # GET /api/v1/identity?bonid=xxx
      def show
        bonid = params[:bonid].to_s.strip

        if oauth_auth?
          # OAuth: return the authenticated user's own identity
          user = current_user
          unless user.bonid_verified?
            return render json: { error: "Itilizatè pa verifye ak BonID." }, status: :not_found
          end
        elsif api_key_auth?
          # API key: lookup by bonid param
          if bonid.blank?
            return render_error("Paramèt 'bonid' obligatwa.", status: :bad_request)
          end
          user = User.find_by(bonid: bonid)
          unless user&.bonid_verified?
            return render json: { error: "BonID '#{bonid}' pa jwenn oswa pa verifye." }, status: :not_found
          end
        end

        response_data = build_identity_response(user)
        filtered = filter_response_by_scopes(response_data)

        render json: {
          success: true,
          identity: filtered,
          granted_scopes: effective_scopes
        }
      end

      private

      SCOPE_FIELDS = {
        "profile" => %i[bonid first_name last_name date_of_birth sex nationality photo_url],
        "email" => %i[email],
        "phone" => %i[phone_number],
        "address" => %i[street locality commune department country],
        "health" => %i[blood_type organ_donor],
        "physical" => %i[height weight eye_color],
        "verification" => %i[bonid_verified verified_at verification_level],
        "criminal_record" => %i[criminal_status criminal_check_at]
      }.freeze

      def build_identity_response(user)
        {
          # Profile
          bonid: user.bonid,
          first_name: user.bonid_first_name,
          last_name: user.bonid_last_name,
          date_of_birth: nil, # Not stored yet
          sex: nil,           # Not stored yet
          nationality: user.bonid_country,
          photo_url: user.bonid_photo_url,

          # Contact
          email: user.email,
          phone_number: user.phone_number,

          # Address
          street: user.bonid_street,
          locality: user.bonid_locality,
          commune: user.bonid_commune,
          department: user.bonid_department,
          country: user.bonid_country,

          # Health
          blood_type: user.bonid_blood_type,
          organ_donor: nil, # Not stored yet

          # Physical (future)
          height: nil,
          weight: nil,
          eye_color: nil,

          # Verification
          bonid_verified: user.bonid_verified?,
          verified_at: user.bonid_verified_at,
          verification_level: user.bonid_verified? ? "full" : "none",

          # Criminal record
          criminal_status: nil,
          criminal_check_at: nil
        }
      end

      def filter_response_by_scopes(response_data)
        return response_data if api_key_auth? # Full access

        allowed_fields = Set.new
        effective_scopes.each do |scope|
          fields = SCOPE_FIELDS[scope]
          allowed_fields.merge(fields) if fields
        end

        response_data.select { |key, _| allowed_fields.include?(key) }
      end

      def effective_scopes
        return OauthClient::VALID_SCOPES if api_key_auth?
        return [] unless current_token

        current_token.granted_scopes
      end
    end
  end
end

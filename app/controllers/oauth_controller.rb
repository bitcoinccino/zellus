class OauthController < ApplicationController
  before_action :authenticate_user!, only: [ :authorize, :decision ]
  skip_before_action :verify_authenticity_token, only: [ :token ]
  skip_before_action :require_cashtag!, only: [ :authorize, :decision, :token ]

  # GET /oauth/authorize?client_id=...&redirect_uri=...&response_type=code&scope=profile+email
  def authorize
    @client = OauthClient.active.find_by(client_id: params[:client_id])

    unless @client
      flash[:alert] = "Aplikasyon pa rekonèt."
      redirect_to root_path
      return
    end

    unless @client.valid_redirect_uri?(params[:redirect_uri])
      flash[:alert] = "Redirect URI pa valid."
      redirect_to root_path
      return
    end

    unless params[:response_type] == "code"
      redirect_to "#{params[:redirect_uri]}?error=unsupported_response_type"
      return
    end

    requested = params[:scope].to_s.split(/[\s+]+/) & OauthClient::VALID_SCOPES
    requested << "openid" unless requested.include?("openid")
    @scopes = requested

    # Check for already-granted scopes (scope upgrade flow)
    existing_token = OauthToken.active.find_by(user: current_user, oauth_client: @client)
    @already_granted = existing_token&.granted_scopes || []

    @redirect_uri = params[:redirect_uri]
    @state = params[:state]

    render :consent, layout: "application"
  end

  # POST /oauth/decision
  def decision
    @client = OauthClient.active.find_by(client_id: params[:client_id])

    unless @client
      render json: { error: "Aplikasyon pa rekonèt." }, status: :bad_request
      return
    end

    redirect_uri = params[:redirect_uri].to_s
    state = params[:state]

    # User denied
    if params[:deny].present?
      redirect_to "#{redirect_uri}?error=access_denied#{"&state=#{state}" if state.present?}", allow_other_host: true
      return
    end

    # Intersect user-selected scopes with what the partner requested
    requested_scopes = params[:requested_scopes].to_s.split(/[\s,]+/) & OauthClient::VALID_SCOPES
    granted = if params[:granted_scopes].present?
                Array(params[:granted_scopes]) & requested_scopes
    else
                requested_scopes # Fallback: grant all requested
    end

    # Always include openid if it was requested
    granted << "openid" if requested_scopes.include?("openid") && !granted.include?("openid")

    # Revoke any existing token for this user+client (scope upgrade replaces)
    OauthToken.where(user: current_user, oauth_client: @client, revoked_at: nil).update_all(revoked_at: Time.current)

    # Create new token with authorization code
    token = OauthToken.create!(
      user: current_user,
      oauth_client: @client,
      scopes: granted.join(" ")
    )

    redirect_params = "code=#{token.authorization_code}"
    redirect_params += "&granted_scopes=#{granted.join("+")}"
    redirect_params += "&state=#{state}" if state.present?

    redirect_to "#{redirect_uri}?#{redirect_params}", allow_other_host: true
  end

  # POST /oauth/token
  # Exchange authorization code for access token
  def token
    client = OauthClient.active.find_by(
      client_id: params[:client_id],
      client_secret: params[:client_secret]
    )

    unless client
      render json: { error: "invalid_client" }, status: :unauthorized
      return
    end

    unless params[:grant_type] == "authorization_code"
      render json: { error: "unsupported_grant_type" }, status: :bad_request
      return
    end

    oauth_token = OauthToken.find_by(
      oauth_client: client,
      authorization_code: params[:code]
    )

    unless oauth_token
      render json: { error: "invalid_grant", error_description: "Kòd otorizasyon pa valid." }, status: :bad_request
      return
    end

    if oauth_token.code_expired?
      render json: { error: "invalid_grant", error_description: "Kòd otorizasyon ekspire." }, status: :bad_request
      return
    end

    unless oauth_token.exchange_code!
      render json: { error: "invalid_grant", error_description: "Kòd deja itilize." }, status: :bad_request
      return
    end

    render json: {
      access_token: oauth_token.access_token,
      token_type: "Bearer",
      expires_in: (oauth_token.expires_at - Time.current).to_i,
      refresh_token: oauth_token.refresh_token,
      scope: oauth_token.scopes,
      granted_scopes: oauth_token.granted_scopes
    }
  end
end

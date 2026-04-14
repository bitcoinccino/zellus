class Admin::DevelopersController < Admin::BaseController
  before_action :set_client, only: [:show, :update, :destroy, :regenerate_secret, :test_webhook]

  def index
    @clients = OauthClient.includes(:webhook_deliveries).order(created_at: :desc)
    @total_clients = @clients.size
    @active_webhooks = @clients.count { |c| c.webhook_active? }
    @deliveries_today = WebhookDelivery.where("created_at >= ?", Time.current.beginning_of_day).count
    @failure_rate = calculate_failure_rate
  end

  def show
    @deliveries = @client.webhook_deliveries.order(created_at: :desc).limit(50)
  end

  def create
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to admin_developers_path, alert: "PIN transfè pa kòrèk."
      return
    end

    client = OauthClient.new(client_params)
    if client.save
      redirect_to admin_developer_path(client), notice: "Kliyan API #{client.name} kreye."
    else
      redirect_to admin_developers_path, alert: client.errors.full_messages.join(". ")
    end
  end

  def update
    if @client.update(update_params)
      redirect_to admin_developer_path(@client), notice: "Kliyan API mete ajou."
    else
      redirect_to admin_developer_path(@client), alert: @client.errors.full_messages.join(". ")
    end
  end

  def destroy
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to admin_developers_path, alert: "PIN transfè pa kòrèk."
      return
    end

    name = @client.name
    @client.destroy!
    redirect_to admin_developers_path, notice: "Kliyan API #{name} efase."
  end

  def regenerate_secret
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to admin_developer_path(@client), alert: "PIN transfè pa kòrèk."
      return
    end

    @client.update!(webhook_secret: SecureRandom.hex(32))
    redirect_to admin_developer_path(@client), notice: "Webhook secret rejenere."
  end

  def test_webhook
    unless @client.webhook_url.present?
      redirect_to admin_developer_path(@client), alert: "Konfigire yon webhook URL anvan."
      return
    end

    payload = {
      event: "test.ping",
      delivery_id: SecureRandom.uuid,
      timestamp: Time.current.iso8601,
      data: { message: "Tès webhook — sa a se yon ping pou verifye koneksyon ou." }
    }

    begin
      uri = URI.parse(@client.webhook_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 10

      request = Net::HTTP::Post.new(uri.request_uri, {
        "Content-Type" => "application/json",
        "X-Zellus-Event" => "test.ping",
        "X-Zellus-Delivery" => payload[:delivery_id],
        "X-Zellus-Signature" => OpenSSL::HMAC.hexdigest("SHA256", @client.webhook_secret.to_s, payload.to_json)
      })
      request.body = payload.to_json

      response = http.request(request)
      redirect_to admin_developer_path(@client), notice: "Tès webhook voye — repons: #{response.code} #{response.message}"
    rescue => e
      redirect_to admin_developer_path(@client), alert: "Tès webhook echwe: #{e.message}"
    end
  end

  private

  def set_client
    @client = OauthClient.find(params[:id])
  end

  def client_params
    params.require(:oauth_client).permit(:name, :redirect_uri, :scopes)
  end

  def update_params
    permitted = params.require(:oauth_client).permit(:name, :redirect_uri, :scopes, :webhook_url, :webhook_active, webhook_events: [])
    # Clean empty strings from webhook_events array
    if permitted[:webhook_events].present?
      permitted[:webhook_events] = permitted[:webhook_events].reject(&:blank?)
    end
    permitted
  end

  def calculate_failure_rate
    recent = WebhookDelivery.where("created_at >= ?", 7.days.ago)
    total = recent.count
    return 0 if total == 0
    failed = recent.where(status: "failed").count
    ((failed.to_f / total) * 100).round(1)
  end
end

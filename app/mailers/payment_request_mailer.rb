class PaymentRequestMailer < ApplicationMailer
  # ── Creator emails ──

  def request_created
    load_payment_request
    mail(to: @creator.email, subject: "Zèllus: Demann peman kreye (##{@payment_request.id})")
  end

  def request_paid
    load_payment_request
    mail(to: @creator.email, subject: "Zèllus: Demann peman peye (##{@payment_request.id})")
  end

  def request_expired
    load_payment_request
    mail(to: @creator.email, subject: "Zèllus: Demann peman ekspire (##{@payment_request.id})")
  end

  def request_canceled
    load_payment_request
    mail(to: @creator.email, subject: "Zèllus: Demann peman anile (##{@payment_request.id})")
  end

  # ── Payer emails ──

  def payer_request_received
    load_payment_request
    return unless @payment_request.payer.present?

    @payer = @payment_request.payer
    mail(to: @payer.email, subject: "Zèllus: #{@creator_name} mande ou #{@amount_display}")
  end

  private

  def load_payment_request
    @payment_request = PaymentRequest.includes(:user).find(params[:payment_request_id])
    @creator         = @payment_request.user
    @creator_name    = @creator.display_name
    @brand_name      = "Zèllus"
    @app_base_url    = ENV["APP_BASE_URL"].to_s.strip
    @share_url       = @app_base_url.present? ? "#{@app_base_url}/r/#{@payment_request.token}" : nil

    @amount_display = if @payment_request.htg?
      "HTG #{format('%.2f', @payment_request.amount.to_f)}"
    else
      "#{format('%.2f', @payment_request.amount.to_f)} #{@payment_request.asset.upcase}"
    end
  end
end

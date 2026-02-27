class TransferMailer < ApplicationMailer
  # ── Sender emails ──

  def sender_funded
    load_transfer
    mail(to: @sender.email, subject: "Priotelus Zellus: Lajan ou depoze (##{@transfer.id})")
  end

  def sender_completed
    load_transfer
    mail(to: @sender.email, subject: "Priotelus Zellus: Transfè konplete (##{@transfer.id})")
  end

  def sender_failed
    load_transfer
    mail(to: @sender.email, subject: "Priotelus Zellus: Transfè echwe (##{@transfer.id})")
  end

  def sender_expired
    load_transfer
    mail(to: @sender.email, subject: "Priotelus Zellus: Transfè ekspire (##{@transfer.id})")
  end

  # ── Receiver emails ──

  def receiver_incoming
    load_transfer
    return unless @transfer.receiver_email.present?

    mail(to: @transfer.receiver_email, subject: "Ou gen lajan! #{@sender_name} voye #{format_htg(@transfer.net_amount)} ba ou")
  end

  def receiver_completed
    load_transfer
    return unless @transfer.receiver_email.present?

    mail(to: @transfer.receiver_email, subject: "Ou resevwa #{format_htg(@transfer.net_amount)} nan MonCash ou")
  end

  private

  def load_transfer
    @transfer    = Transfer.includes(:user).find(params[:transfer_id])
    @sender      = @transfer.user
    @sender_name = @sender.email.split("@").first.capitalize
    @brand_name  = "Priotelus Bank"
    @app_base_url = ENV["APP_BASE_URL"].to_s.strip
    @claim_url   = @app_base_url.present? ? "#{@app_base_url}/t/#{@transfer.token}" : nil
  end

  def format_htg(value)
    "HTG #{format('%.0f', value.to_f)}"
  end
end

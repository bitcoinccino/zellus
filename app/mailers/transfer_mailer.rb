class TransferMailer < ApplicationMailer
  # ── Sender emails ──

  def sender_funded
    load_transfer
    mail(to: @sender.email, subject: "Zèllus: Lajan ou depoze (##{@transfer.id})")
  end

  def sender_completed
    load_transfer
    mail(to: @sender.email, subject: "Zèllus: Transfè konplete (##{@transfer.id})")
  end

  def sender_failed
    load_transfer
    mail(to: @sender.email, subject: "Zèllus: Transfè echwe (##{@transfer.id})")
  end

  def sender_expired
    load_transfer
    mail(to: @sender.email, subject: "Zèllus: Transfè ekspire (##{@transfer.id})")
  end

  # ── Receiver emails ──

  def receiver_incoming
    load_transfer
    return unless @transfer.receiver_email.present?

    mail(to: @transfer.receiver_email, subject: "Ou gen lajan! #{@sender_name} voye #{format_amount(@transfer)} ba ou")
  end

  def receiver_completed
    load_transfer
    return unless @transfer.receiver_email.present?

    subject = if @transfer.usdc_wallet_transfer?
                "Ou resevwa #{format_amount(@transfer)} nan Zèllus ou"
              else
                "Ou resevwa #{format_amount(@transfer)} nan MonCash ou"
              end
    mail(to: @transfer.receiver_email, subject: subject)
  end

  private

  def load_transfer
    @transfer    = Transfer.includes(:user).find(params[:transfer_id])
    @sender      = @transfer.user
    @sender_name = @sender.display_name
    @brand_name  = "Zèllus"
    @app_base_url = ENV["APP_BASE_URL"].to_s.strip
    @claim_url   = @app_base_url.present? ? "#{@app_base_url}/t/#{@transfer.token}" : nil

    # Shared display helpers for templates
    @is_usdc_wallet  = @transfer.usdc_wallet_transfer?
    @is_usdc_address = @transfer.usdc_address_transfer?
    @is_crypto       = @transfer.crypto_transfer?
    @receiver_display = receiver_display_text
    @amount_display   = format_amount(@transfer)
    @basescan_url     = basescan_url
    @fee_display      = fee_display_text
    @net_display      = net_display_text
  end

  def format_htg(value)
    "HTG #{format('%.0f', value.to_f)}"
  end

  def format_amount(transfer)
    if transfer.usdc_wallet_transfer? || transfer.usdc_address_transfer?
      usdc = transfer.crypto_amount || transfer.net_amount
      "#{format('%.2f', usdc.to_f)} USD"
    elsif transfer.crypto_transfer? && transfer.crypto_amount.present?
      "#{transfer.crypto_amount} #{transfer.asset_label}"
    else
      "HTG #{format('%.0f', transfer.net_amount.to_f)}"
    end
  end

  def receiver_display_text
    if @transfer.receiver_cashtag.present?
      "$#{@transfer.receiver_cashtag}"
    elsif @transfer.receiver_phone.present?
      @transfer.receiver_phone
    elsif @transfer.receiver_wallet_address.present?
      "#{@transfer.receiver_wallet_address.first(6)}...#{@transfer.receiver_wallet_address.last(4)}"
    elsif @transfer.receiver_email.present?
      @transfer.receiver_email
    else
      "—"
    end
  end

  def basescan_url
    return nil unless @transfer.blockchain_tx_hash.present?
    base = CryptoTransferWorker::CHAIN_ID == 8453 ? "https://basescan.org" : "https://sepolia.basescan.org"
    "#{base}/tx/#{@transfer.blockchain_tx_hash}"
  end

  def fee_display_text
    if @transfer.wallet_payout? || @is_usdc_wallet
      "Gratis (0%)"
    else
      "HTG #{format('%.0f', @transfer.fee.to_f)} (1%)"
    end
  end

  def net_display_text
    if @is_usdc_wallet || @is_usdc_address
      usdc = @transfer.crypto_amount || @transfer.net_amount
      "#{format('%.2f', usdc.to_f)} USD"
    elsif @is_crypto && @transfer.crypto_amount.present?
      "#{@transfer.crypto_amount} #{@transfer.asset_label}"
    else
      "HTG #{format('%.0f', @transfer.net_amount.to_f)}"
    end
  end
end

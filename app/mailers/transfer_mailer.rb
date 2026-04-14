class TransferMailer < ApplicationMailer
  # ── Sender emails ──

  def sender_funded
    load_transfer
    mail(to: @sender.email, subject: "Zèllus: Ou peye #{@receiver_display} ~ #{@amount_display} (an atant)")
  end

  def sender_completed
    load_transfer
    mail(to: @sender.email, subject: "Zèllus: Ou peye #{@receiver_display} ~ #{@amount_display} ✓")
  end

  def sender_failed
    load_transfer
    mail(to: @sender.email, subject: "Zèllus: Peman bay #{@receiver_display} echwe")
  end

  def sender_expired
    load_transfer
    mail(to: @sender.email, subject: "Zèllus: Peman bay #{@receiver_display} ekspire")
  end

  # ── Receiver emails ──

  def receiver_incoming
    load_transfer
    return unless @transfer.receiver_email.present?

    mail(to: @transfer.receiver_email, subject: "Zèllus: #{@sender_name} peye w #{@amount_display}")
  end

  def receiver_completed
    load_transfer
    return unless @transfer.receiver_email.present?

    mail(to: @transfer.receiver_email, subject: "Zèllus: Ou resevwa #{@amount_display} ✓")
  end

  private

  def load_transfer
    @transfer    = Transfer.includes(:user, :business).find(params[:transfer_id])
    @sender      = @transfer.user
    @sender_name = @sender.display_name
    @brand_name  = AppBrand::NAME
    @app_base_url = ENV["APP_BASE_URL"].to_s.strip
    @claim_url   = @app_base_url.present? ? "#{@app_base_url}/t/#{@transfer.token}" : nil

    # Shared display helpers for templates
    @is_usd_wallet  = @transfer.usd_wallet_transfer?
    @is_usd_address = @transfer.usd_address_transfer?
    @is_crypto       = @transfer.crypto_transfer?
    @receiver_display = receiver_display_text
    @receiver_type    = receiver_type_label
    @amount_display   = format_amount(@transfer)
    @basescan_url     = basescan_url
    @fee_display      = fee_display_text
    @net_display      = net_display_text
  end

  def format_htg(value)
    "HTG #{format('%.0f', value.to_f)}"
  end

  def format_amount(transfer)
    if transfer.usd_wallet_transfer? || transfer.usd_address_transfer?
      usd = transfer.crypto_amount || transfer.net_amount
      "#{format('%.2f', usd.to_f)} USD"
    elsif transfer.crypto_transfer? && transfer.crypto_amount.present?
      "#{transfer.crypto_amount} #{transfer.asset_label}"
    else
      "HTG #{format('%.0f', transfer.net_amount.to_f)}"
    end
  end

  def receiver_display_text
    if @transfer.business.present?
      @transfer.business.name
    elsif @transfer.receiver_cashtag.present?
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

  def receiver_type_label
    if @transfer.business.present?
      "Biznis"
    elsif @transfer.receiver_wallet_address.present? && @transfer.receiver_cashtag.blank?
      "Adrès Ekstèn"
    else
      "Itilizatè Zèllus"
    end
  end

  def basescan_url
    return nil unless @transfer.blockchain_tx_hash.present?
    base = CryptoTransferWorker::CHAIN_ID == 8453 ? "https://basescan.org" : "https://sepolia.basescan.org"
    "#{base}/tx/#{@transfer.blockchain_tx_hash}"
  end

  def fee_display_text
    if @transfer.wallet_payout? || @is_usd_wallet
      "Gratis (0%)"
    elsif @transfer.crypto_transfer? && @transfer.exchange_rate.to_f > 0
      fee_in_asset = @transfer.fee.to_f / @transfer.exchange_rate.to_f
      "#{format('%.2f', fee_in_asset)} #{@transfer.asset_label} (1%)"
    else
      "HTG #{format('%.0f', @transfer.fee.to_f)} (1%)"
    end
  end

  def net_display_text
    if @is_usd_wallet || @is_usd_address
      usd = @transfer.crypto_amount || @transfer.net_amount
      "#{format('%.2f', usd.to_f)} USD"
    elsif @is_crypto && @transfer.crypto_amount.present?
      "#{@transfer.crypto_amount} #{@transfer.asset_label}"
    else
      "HTG #{format('%.0f', @transfer.net_amount.to_f)}"
    end
  end
end

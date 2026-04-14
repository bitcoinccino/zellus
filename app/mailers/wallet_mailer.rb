class WalletMailer < ApplicationMailer
  # ── Deposit confirmed (USD or HTG) ──
  def deposit_confirmed
    load_common
    @tx_hash = params[:tx_hash]
    basescan_base = CryptoTransferWorker::CHAIN_ID == 8453 ? "https://basescan.org" : "https://sepolia.basescan.org"
    @basescan_url = @tx_hash.present? ? "#{basescan_base}/tx/#{@tx_hash}" : nil

    mail(to: @user.email, subject: "Zèllus: Ou depoze #{@amount_display} ✓")
  end

  # ── USD withdrawal sent on-chain ──
  def withdrawal_sent
    load_common
    @tx_hash    = params[:tx_hash]
    @to_address = params[:to_address]
    basescan_base = CryptoTransferWorker::CHAIN_ID == 8453 ? "https://basescan.org" : "https://sepolia.basescan.org"
    @basescan_url = @tx_hash.present? ? "#{basescan_base}/tx/#{@tx_hash}" : nil
    @address_short = @to_address.present? ? "#{@to_address[0..5]}...#{@to_address[-4..]}" : "—"

    mail(to: @user.email, subject: "Zèllus: Ou retire #{@amount_display} ✓")
  end

  # ── USD withdrawal failed + refunded ──
  def withdrawal_failed
    load_common
    @reason = params[:reason].to_s.truncate(200)

    mail(to: @user.email, subject: "Zèllus: Retrè #{@amount_display} echwe — lajan ranbouse")
  end

  # ── HTG MonCash withdrawal queued ──
  def withdrawal_queued
    load_common
    @phone   = params[:phone]
    @instant = params[:instant]
    @fee     = params[:fee] || 0

    mail(to: @user.email, subject: "Zèllus: Ou retire #{@amount_display} (an kou)")
  end

  # ── Bank withdrawal queued (pending admin processing) ──
  def bank_withdrawal_queued
    load_common
    @bank_name    = params[:bank_name] || "UNIBANK"
    @bank_account = params[:bank_account]
    @account_holder = params[:account_holder]
    @fee          = params[:fee] || 0

    mail(to: @user.email, subject: "Zèllus: Ou retire #{@amount_display} bank (an kou)")
  end

  # ── Bank withdrawal completed by admin ──
  def bank_withdrawal_completed
    load_common
    @bank_name        = params[:bank_name] || "UNIBANK"
    @bank_account     = params[:bank_account]
    @reference_number = params[:reference_number]

    mail(to: @user.email, subject: "Zèllus: Retrè bank #{@amount_display} fini ✓")
  end

  # ── Bank withdrawal failed + refunded ──
  def bank_withdrawal_failed
    load_common
    @bank_name    = params[:bank_name] || "UNIBANK"
    @bank_account = params[:bank_account]
    @reason       = params[:reason].to_s.truncate(200)

    mail(to: @user.email, subject: "Zèllus: Retrè bank #{@amount_display} echwe — lajan ranbouse")
  end

  private

  def load_common
    @user   = User.find(params[:user_id])
    @amount = params[:amount]
    @asset  = params[:asset] || "htg"
    @amount_display = case @asset.to_s.downcase
                      when "usd"
                        "#{format('%.2f', @amount.to_f)} USD"
                      when "eth"
                        "#{format('%.6f', @amount.to_f)} ETH"
                      when "wbtc"
                        "#{format('%.8f', @amount.to_f)} WBTC"
                      else
                        "HTG #{format('%.0f', @amount.to_f)}"
                      end
    @app_base_url = ENV["APP_BASE_URL"].to_s.strip
  end
end

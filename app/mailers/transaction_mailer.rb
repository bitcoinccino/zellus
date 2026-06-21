class TransactionMailer < ApplicationMailer
  include ApplicationHelper
  helper TransactionMailerHelper

  def created
    load_transaction
    @crypto_display = crypto_display_label
    mail(to: @user.email, subject: "Zèllus: #{@transaction.buy? ? 'Ou achte' : 'Ou vann'} #{@crypto_display} (an atant)")
  end

  def completed
    load_transaction
    @crypto_display = crypto_display_label
    subject = if @transaction.admin_credit_external?
                "Zèllus: #{@crypto_display} voye sou Base ✓"
    else
                "Zèllus: #{@transaction.buy? ? 'Ou achte' : 'Ou vann'} #{@crypto_display} ✓"
    end
    mail(to: @user.email, subject: subject)
  end

  def failed
    load_transaction
    @crypto_display = crypto_display_label
    subject = if @transaction.admin_credit_external?
                "Zèllus: Kredi Ekstèn #{@crypto_display} echwe"
    else
                "Zèllus: #{@transaction.buy? ? 'Acha' : 'Vann'} #{@crypto_display} echwe"
    end
    mail(to: @user.email, subject: subject)
  end

  private

  def load_transaction
    @transaction = Transaction.includes(:user).find(params[:transaction_id])
    @user = @transaction.user
    @brand_name = AppBrand::NAME
    @app_base_url = ENV["APP_BASE_URL"].to_s.strip
    @transaction_url = @app_base_url.present? ? "#{@app_base_url}/transactions/#{@transaction.token}" : nil
    @basescan_url = @transaction.blockchain_tx_hash.present? ? basescan_tx_url(@transaction.blockchain_tx_hash) : nil

    # Dynamic labels for the view
    @payment_method_label = payment_method_label
    @source_label = source_label
    @destination_label = destination_label
    @amount_line = amount_line
    @network_label = network_label
    @customer_failure_message = customer_failure_message
  end

  def subject_prefix
    if @transaction.loan_request?
      "Zèllus Pionye Prè"
    elsif @transaction.failure_reason&.include?("REPAYMENT_LOAN_")
      "Zèllus Ranbousman Prè"
    elsif @transaction.buy?
      "Zèllus Achte"
    else
      "Zèllus Vann"
    end
  end

  def payment_method_label
    if @transaction.admin_credit_external?
      "Zèllus Kredi Ekstèn (Base Mainnet)"
    elsif @transaction.loan_request?
      "Peman MonCash (Liy Kredi Pionye)"
    elsif @transaction.failure_reason&.include?("REPAYMENT_LOAN_")
      "Regleman Dèt (#{@transaction.buy? ? 'MonCash' : 'USD'})"
    elsif @transaction.buy?
      "MonCash"
    else
      "Peman MonCash bay #{@transaction.moncash_phone.presence || 'resevè'} apre depo Base"
    end
  end

  def source_label
    if @transaction.admin_credit_external?
      "Trezori Zèllus (Base Mainnet)"
    elsif @transaction.loan_request?
      "Trezò Zèllus"
    elsif @transaction.failure_reason&.include?("REPAYMENT_LOAN_")
      "Bous Itilizatè (Ranbousman Dèt)"
    elsif @transaction.buy?
      "Bous MonCash (HTG)"
    else
      "Bous USD itilizatè sou Base"
    end
  end

  def destination_label
    if @transaction.admin_credit_external?
      @transaction.destination_address.to_s
    elsif @transaction.buy? && !@transaction.failure_reason&.include?("REPAYMENT_LOAN_")
      @transaction.destination_address.to_s
    elsif @transaction.failure_reason&.include?("REPAYMENT_LOAN_")
      "Trezò Zèllus (Dèt Regle)"
    else
      @transaction.moncash_phone.presence || "Resevè MonCash"
    end
  end

  def amount_line
    if @transaction.admin_credit_external?
      "#{@transaction.crypto_amount} USD"
    elsif @transaction.loan_request?
      "Montan Prè: #{format_htg(@transaction.fiat_amount)}"
    elsif @transaction.failure_reason&.include?("REPAYMENT_LOAN_")
      "Montan Ranbousman: #{format_htg(@transaction.fiat_amount)} (Dèt Regle)"
    elsif @transaction.buy?
      "#{format_htg(@transaction.fiat_amount)} → #{@transaction.crypto_amount} #{@transaction.crypto_currency.upcase}"
    else
      "#{@transaction.crypto_amount} #{@transaction.crypto_currency.upcase} → #{format_htg(@transaction.fiat_amount)}"
    end
  end

  def network_label
    if @transaction.loan_request? || @transaction.failure_reason&.include?("REPAYMENT_LOAN_")
      "Regleman Entèn MonCash"
    else
      @transaction.buy? ? "Rezo Base" : "Depo Base + Peman MonCash"
    end
  end

  def crypto_display_label
    currency = @transaction.crypto_currency&.upcase == "USD" ? "USD" : @transaction.crypto_currency&.upcase
    "#{@transaction.crypto_amount} #{currency}"
  end

  def format_htg(value)
    "HTG #{format('%.2f', value.to_f)}"
  end

  def customer_failure_message
    return "Yon erè inatandi rive. Tanpri kontakte sipò." if @transaction.failure_reason.blank?

    if @transaction.admin_credit_external? && @transaction.failure_reason.include?("exceeds balance")
      "Trezori a pa gen ase USD pou voye #{@transaction.crypto_amount} USD. Tanpri depoze plis USD nan trezori a epi eseye ankò."
    elsif @transaction.loan_request? && @transaction.failure_reason.include?("active")
      "Kont MonCash ou dwe aktif pou resevwa yon Prè Pionye. Tanpri verifye estati Digicel ou."
    else
      @transaction.friendly_failure_reason
    end
  end
end

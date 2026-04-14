class AgentTransactionsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_business
  before_action :ensure_agent!

  # ── POST /business/agent_transactions ──
  def create
    case params[:transaction_type]
    when "float_top_up"
      handle_float_top_up
    when "float_withdraw"
      handle_float_withdraw
    else
      handle_cash_in
    end
  end

  # ── GET /business/agent_transactions ──
  def index
    @agent_transactions = @business.agent_transactions
                                    .includes(:customer)
                                    .recent_first
                                    .limit(50)
  end

  private

  # ── Cash-In: Customer gives cash → Agent credits wallet ──
  def handle_cash_in
    customer = find_customer(params[:customer_identifier])

    unless customer
      redirect_to wallet_path, alert: "Kliyan pa jwenn. Verifye $zellustag oswa nimewo telefòn."
      return
    end

    if customer.id == current_user.id
      redirect_to wallet_path, alert: "Ou pa ka fè depo nan pwòp kont ou."
      return
    end

    amount = params[:amount].to_f
    idempotency_key = params[:idempotency_key].presence

    begin
      agent_tx = AgentService.new(@business).cash_in!(
        customer: customer,
        amount: amount,
        notes: params[:notes].to_s.strip.presence,
        idempotency_key: idempotency_key
      )

      redirect_to wallet_path,
        notice: "Depo #{amount.to_i} HTG bay $#{customer.cashtag} reyisi! Kòd: #{agent_tx.confirmation_code}"

    rescue AgentService::DuplicateTransactionError => e
      redirect_to wallet_path, alert: e.message
    rescue AgentService::InsufficientFloatError => e
      redirect_to wallet_path, alert: e.message
    rescue AgentService::AmountOutOfRangeError => e
      redirect_to wallet_path, alert: e.message
    rescue AgentService::AgentNotActiveError
      redirect_to wallet_path, alert: "Kont ajan ou pa aktif. Kontakte sipò."
    rescue WalletService::FrozenAccountError
      redirect_to wallet_path, alert: "Pòtfèy kliyan an jele. Pa ka fè depo."
    rescue => e
      Rails.logger.error "[AgentTransaction] Unexpected error: #{e.class} — #{e.message}"
      redirect_to wallet_path, alert: "Erè inatandi. Tanpri eseye ankò."
    end
  end

  # ── Float Top-Up: Agent wallet → float ──
  def handle_float_top_up
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to wallet_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

    amount = params[:amount].to_f
    idempotency_key = params[:idempotency_key].presence

    begin
      agent_tx = AgentService.new(@business).top_up_float!(
        amount: amount,
        idempotency_key: idempotency_key
      )

      redirect_to wallet_path,
        notice: "G #{amount.to_i} ajoute nan flòt ou! Kòd: #{agent_tx.confirmation_code}"

    rescue AgentService::DuplicateTransactionError => e
      redirect_to wallet_path, alert: e.message
    rescue AgentService::AmountOutOfRangeError => e
      redirect_to wallet_path, alert: e.message
    rescue AgentService::AgentNotActiveError
      redirect_to wallet_path, alert: "Kont ajan ou pa aktif. Kontakte sipò."
    rescue WalletService::InsufficientFundsError => e
      redirect_to wallet_path, alert: e.message
    rescue => e
      Rails.logger.error "[AgentTransaction] Float top-up error: #{e.class} — #{e.message}"
      redirect_to wallet_path, alert: "Erè inatandi. Tanpri eseye ankò."
    end
  end

  # ── Float Withdraw: Agent float → wallet ──
  def handle_float_withdraw
    unless current_user.verify_transfer_pin(params[:transfer_pin])
      redirect_to wallet_path, alert: "PIN pa kòrèk. Tanpri eseye ankò."
      return
    end

    amount = params[:amount].to_f
    idempotency_key = params[:idempotency_key].presence

    begin
      agent_tx = AgentService.new(@business).withdraw_float!(
        amount: amount,
        idempotency_key: idempotency_key
      )

      redirect_to wallet_path,
        notice: "G #{amount.to_i} retire nan flòt ou! Kòd: #{agent_tx.confirmation_code}"

    rescue AgentService::DuplicateTransactionError => e
      redirect_to wallet_path, alert: e.message
    rescue AgentService::InsufficientFloatError => e
      redirect_to wallet_path, alert: e.message
    rescue AgentService::AmountOutOfRangeError => e
      redirect_to wallet_path, alert: e.message
    rescue AgentService::AgentNotActiveError
      redirect_to wallet_path, alert: "Kont ajan ou pa aktif. Kontakte sipò."
    rescue => e
      Rails.logger.error "[AgentTransaction] Float withdraw error: #{e.class} — #{e.message}"
      redirect_to wallet_path, alert: "Erè inatandi. Tanpri eseye ankò."
    end
  end

  def load_business
    @business = current_user.business
  end

  def ensure_agent!
    unless @business&.agent?
      redirect_to wallet_path, alert: "Ou pa gen aksè ajan."
    end
  end

  # Find customer by $cashtag or 509XXXXXXXX phone
  def find_customer(identifier)
    return nil if identifier.blank?

    identifier = identifier.to_s.strip

    # Try cashtag (with or without $)
    tag = identifier.delete_prefix("$").downcase
    user = User.find_by("LOWER(cashtag) = ?", tag)
    return user if user

    # Try phone number
    phone = identifier.gsub(/\D/, "")
    phone = "509#{phone}" if phone.length == 8  # Auto-prefix 509
    user = User.find_by(phone_number: phone) if phone.match?(/\A509\d{8}\z/)
    return user if user

    nil
  end
end

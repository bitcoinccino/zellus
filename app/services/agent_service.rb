class AgentService
  class AgentNotActiveError < StandardError; end
  class CustomerNotFoundError < StandardError; end
  class InsufficientFloatError < StandardError; end
  class AmountOutOfRangeError < StandardError; end
  class DuplicateTransactionError < StandardError; end

  def initialize(business)
    @business = business
  end

  # ── Cash-In: Customer gives cash → Agent credits wallet ──
  # Returns the completed AgentTransaction
  #
  # Idempotency: pass an idempotency_key (client-generated UUID) to prevent
  # double-tap on slow 4G connections in Port-au-Prince.
  def cash_in!(customer:, amount:, notes: nil, idempotency_key: nil)
    amount = amount.to_d

    # ── Pre-validation (outside transaction for fast failure) ──
    validate_agent_active!
    validate_amount!(amount)

    # ── Idempotency check ──
    if idempotency_key.present?
      existing = AgentTransaction.find_by(idempotency_key: idempotency_key)
      if existing
        raise DuplicateTransactionError, "Tranzaksyon sa a deja trete (#{existing.confirmation_code})"
      end
    end

    customer_wallet = customer.ensure_wallet!
    commission_rate = @business.agent_commission_rate
    commission = (amount * commission_rate).round(2)
    agent_tx = nil
    ledger_entry = nil

    # ── Atomic transaction with requires_new for nested safety ──
    ActiveRecord::Base.transaction(requires_new: true) do
      # 1. Lock the business record to prevent float overspending
      @business.lock!

      # Re-check float after lock (another agent tx could have drained it)
      unless @business.agent_float_sufficient?(amount)
        raise InsufficientFloatError,
              "Flòt ajan pa sifi. Bezwen #{amount.to_i} HTG, disponib: #{@business.agent_float_htg.to_i} HTG"
      end

      # 2. Create AgentTransaction (pending)
      agent_tx = AgentTransaction.create!(
        business: @business,
        customer: customer,
        amount: amount,
        currency: "HTG",
        transaction_type: "cash_in",
        commission_rate: commission_rate,
        commission_amount: commission,
        status: "pending",
        idempotency_key: idempotency_key,
        notes: notes
      )

      # 3. Debit agent's float (business.total_received)
      @business.decrement!(:total_received, amount)

      # 4. Credit customer's wallet (creates WalletLedgerEntry for audit trail)
      ws = WalletService.new(customer_wallet)
      ws.deposit!(
        amount: amount,
        asset: "htg",
        reference: agent_tx,
        description: "Depo lajan kach via ajan #{@business.name} (#{agent_tx.confirmation_code})"
      )

      # 5. Link the ledger entry to the agent transaction for auditing
      ledger_entry = customer_wallet.wallet_ledger_entries.where(reference: agent_tx).last
      agent_tx.update!(wallet_ledger_entry: ledger_entry) if ledger_entry

      # 6. Credit commission back to agent's float + track total earned
      @business.increment!(:total_received, commission)
      @business.increment!(:total_commission_earned, commission)

      # 7. Mark completed
      agent_tx.update!(status: "completed")
    end

    # ── Notifications (outside transaction — non-critical) ──
    send_notifications(agent_tx, customer)

    agent_tx
  end

  # ── Float Top-Up: Agent moves HTG from wallet → float ──
  # Zero fees, zero commission. Internal transfer only.
  def top_up_float!(amount:, idempotency_key: nil)
    amount = amount.to_d

    validate_agent_active!
    raise AmountOutOfRangeError, "Montan dwe plis pase 0" unless amount > 0

    # ── Idempotency check ──
    if idempotency_key.present?
      existing = AgentTransaction.find_by(idempotency_key: idempotency_key)
      if existing
        raise DuplicateTransactionError, "Tranzaksyon sa a deja trete (#{existing.confirmation_code})"
      end
    end

    agent_user = @business.user
    wallet = agent_user.ensure_wallet!
    agent_tx = nil

    ActiveRecord::Base.transaction(requires_new: true) do
      # 1. Lock both business and wallet
      @business.lock!
      wallet.lock!

      # 2. Verify wallet has enough HTG
      unless wallet.htg_balance >= amount
        raise WalletService::InsufficientFundsError,
              "Balans pòtfèy pa sifi. Bezwen #{amount.to_i} HTG, disponib: #{wallet.htg_balance.to_i} HTG"
      end

      # 3. Create AgentTransaction (float_top_up, commission = 0)
      agent_tx = AgentTransaction.create!(
        business: @business,
        customer: agent_user,
        amount: amount,
        currency: "HTG",
        transaction_type: "float_top_up",
        commission_rate: 0,
        commission_amount: 0,
        status: "pending",
        idempotency_key: idempotency_key,
        notes: "Ajoute flòt depi pòtfèy"
      )

      # 4. Debit wallet (manual ledger entry — no fees)
      new_balance = wallet.htg_balance - amount
      wallet.wallet_ledger_entries.create!(
        user: agent_user,
        entry_type: "withdrawal",
        asset: "htg",
        amount: amount,
        balance_after: new_balance,
        reference: agent_tx,
        description: "Ajoute flòt ajan — #{amount.to_i} HTG (#{agent_tx.confirmation_code})"
      )
      wallet.update!(htg_balance: new_balance)

      # 5. Credit agent float
      @business.increment!(:total_received, amount)

      # 6. Mark completed
      agent_tx.update!(status: "completed")
    end

    agent_tx
  end

  # ── Float Withdraw: Agent moves HTG from float → wallet ──
  # Zero fees, zero commission. Internal transfer only.
  def withdraw_float!(amount:, idempotency_key: nil)
    amount = amount.to_d

    validate_agent_active!
    raise AmountOutOfRangeError, "Montan dwe plis pase 0" unless amount > 0

    # ── Idempotency check ──
    if idempotency_key.present?
      existing = AgentTransaction.find_by(idempotency_key: idempotency_key)
      if existing
        raise DuplicateTransactionError, "Tranzaksyon sa a deja trete (#{existing.confirmation_code})"
      end
    end

    agent_user = @business.user
    wallet = agent_user.ensure_wallet!
    agent_tx = nil

    ActiveRecord::Base.transaction(requires_new: true) do
      # 1. Lock both business and wallet
      @business.lock!
      wallet.lock!

      # 2. Verify float has enough
      unless @business.agent_float_sufficient?(amount)
        raise InsufficientFloatError,
              "Flòt ajan pa sifi. Bezwen #{amount.to_i} HTG, disponib: #{@business.agent_float_htg.to_i} HTG"
      end

      # 3. Create AgentTransaction (float_withdraw, commission = 0)
      agent_tx = AgentTransaction.create!(
        business: @business,
        customer: agent_user,
        amount: amount,
        currency: "HTG",
        transaction_type: "float_withdraw",
        commission_rate: 0,
        commission_amount: 0,
        status: "pending",
        idempotency_key: idempotency_key,
        notes: "Retire flòt nan pòtfèy"
      )

      # 4. Debit float
      @business.decrement!(:total_received, amount)

      # 5. Credit wallet (manual ledger entry — no fees)
      new_balance = wallet.htg_balance + amount
      wallet.wallet_ledger_entries.create!(
        user: agent_user,
        entry_type: "deposit",
        asset: "htg",
        amount: amount,
        balance_after: new_balance,
        reference: agent_tx,
        description: "Retire flòt ajan — #{amount.to_i} HTG (#{agent_tx.confirmation_code})"
      )
      wallet.update!(htg_balance: new_balance)

      # 6. Mark completed
      agent_tx.update!(status: "completed")
    end

    agent_tx
  end

  private

  def validate_agent_active!
    unless @business.agent?
      raise AgentNotActiveError, "Biznis sa a pa yon ajan aktif"
    end
  end

  def validate_amount!(amount)
    if amount < AgentTransaction::CASH_IN_MIN
      raise AmountOutOfRangeError,
            "Montan minimòm se #{AgentTransaction::CASH_IN_MIN} HTG"
    end
    if amount > AgentTransaction::CASH_IN_MAX
      raise AmountOutOfRangeError,
            "Montan maksimòm se #{AgentTransaction::CASH_IN_MAX} HTG"
    end
  end

  def send_notifications(agent_tx, customer)
    # Notify customer: "Ou resevwa X HTG nan men [Agent Name]. Kòd: ABC123"
    NotificationService.agent_cash_in_received(agent_tx)

    # Notify agent: "Depo X HTG bay $cashtag konplete. Komisyon: Y HTG"
    NotificationService.agent_cash_in_completed(agent_tx)
  rescue => e
    Rails.logger.error "[AgentService] Notification error: #{e.message}"
  end
end

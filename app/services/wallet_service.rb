class WalletService
  class InsufficientFundsError < StandardError; end
  class FrozenAccountError < StandardError; end
  class InvalidAmountError < StandardError; end
  class DuplicateDepositError < StandardError; end

  # ── Instant withdrawal fee ──
  INSTANT_FEE_RATE = BigDecimal("0.008")  # 0.8%
  INSTANT_FEE_MIN  = BigDecimal("25")     # 25 HTG minimum

  def self.calculate_instant_fee(amount)
    [amount.to_d * INSTANT_FEE_RATE, INSTANT_FEE_MIN].max.round(2)
  end

  def initialize(wallet)
    @wallet = wallet
  end

  # ── Deposit HTG from MonCash into wallet ──
  def deposit!(amount:, moncash_transaction_id: nil, reference: nil, description: nil)
    validate_amount!(amount)
    ensure_open!

    # Idempotency: prevent double-credit on callback retry
    if moncash_transaction_id.present? &&
       WalletLedgerEntry.exists?(moncash_transaction_id: moncash_transaction_id)
      raise DuplicateDepositError, "Depo sa a deja trete (#{moncash_transaction_id})"
    end

    ActiveRecord::Base.transaction do
      @wallet.lock!

      new_balance = @wallet.htg_balance + amount

      entry = @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "deposit",
        amount: amount,
        balance_after: new_balance,
        moncash_transaction_id: moncash_transaction_id,
        reference: reference,
        description: description || "Depo MonCash — #{amount.to_i} HTG"
      )

      @wallet.update!(htg_balance: entry.balance_after)
    end
  end

  # ── Withdraw HTG from wallet (debits immediately, worker sends MonCash) ──
  # instant: false → standard (48h, free) | instant: true → immediate (0.8% fee, min 25 HTG)
  def withdraw!(amount:, instant: false)
    validate_amount!(amount)
    ensure_open!

    fee = instant ? self.class.calculate_instant_fee(amount) : BigDecimal("0")
    total_debit = amount.to_d + fee

    ActiveRecord::Base.transaction do
      @wallet.lock!

      unless @wallet.htg_balance >= total_debit
        raise InsufficientFundsError,
              "Balans pa sifi: #{@wallet.htg_balance} HTG, bezwen #{total_debit.to_i} HTG"
      end

      running_balance = @wallet.htg_balance

      # 1. Main withdrawal entry
      running_balance -= amount.to_d
      withdrawal_entry = @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "withdrawal",
        amount: amount.to_d,
        balance_after: running_balance,
        description: instant ? "Retire instant via MonCash" : "Retire estanda via MonCash (48 èdtan)"
      )

      # 2. Instant fee entry (if applicable)
      if fee > 0
        running_balance -= fee
        @wallet.wallet_ledger_entries.create!(
          user: @wallet.user,
          entry_type: "instant_fee",
          amount: fee,
          balance_after: running_balance,
          description: "Frè retire instant (0.8%, min 25 HTG)"
        )
      end

      @wallet.update!(htg_balance: running_balance)
      withdrawal_entry
    end
  end

  # ── Deduct for a Zellus transfer (sender pays from wallet) ──
  def transfer_out!(amount:, fee:, transfer:)
    validate_amount!(amount)
    ensure_open!

    ActiveRecord::Base.transaction do
      @wallet.lock!

      unless @wallet.sufficient_balance?(amount)
        raise InsufficientFundsError,
              "Balans pa sifi pou transfè: #{@wallet.htg_balance} HTG, bezwen #{amount} HTG"
      end

      remaining = @wallet.htg_balance
      net = amount - fee

      # 1. Transfer amount (net of fee)
      remaining -= net
      @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "transfer_out",
        amount: net,
        balance_after: remaining,
        reference: transfer,
        description: "Transfè bay #{transfer.receiver_name.presence || transfer.receiver_display}"
      )

      # 2. Fee (separate entry for transparency)
      if fee > 0
        remaining -= fee
        @wallet.wallet_ledger_entries.create!(
          user: @wallet.user,
          entry_type: "fee",
          amount: fee,
          balance_after: remaining,
          reference: transfer,
          description: "Frè sèvis 1% — Transfè ##{transfer.id}"
        )
      end

      @wallet.update!(htg_balance: remaining)
    end
  end

  # ── Credit receiver's wallet (auto-credit for registered users) ──
  def transfer_in!(amount:, transfer:, sender_user:)
    validate_amount!(amount)
    ensure_open!

    ActiveRecord::Base.transaction do
      @wallet.lock!

      new_balance = @wallet.htg_balance + amount
      sender_name = sender_user.email.split("@").first.capitalize

      entry = @wallet.wallet_ledger_entries.create!(
        user: sender_user,
        entry_type: "transfer_in",
        amount: amount,
        balance_after: new_balance,
        reference: transfer,
        description: "Resevwa #{amount.to_i} HTG de #{sender_name}"
      )

      @wallet.update!(htg_balance: entry.balance_after)
    end
  end

  # ── Refund (failed withdrawal, failed transfer, etc.) ──
  def refund!(amount:, reference: nil, reason: nil)
    validate_amount!(amount)
    ensure_open!

    ActiveRecord::Base.transaction do
      @wallet.lock!

      new_balance = @wallet.htg_balance + amount

      entry = @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "refund",
        amount: amount,
        balance_after: new_balance,
        reference: reference,
        description: reason || "Ranbousman — #{amount.to_i} HTG"
      )

      @wallet.update!(htg_balance: entry.balance_after)
    end
  end

  # ── Hold wallet (suspicious activity) ──
  def hold!
    @wallet.update!(status: :held)
  end

  private

  def ensure_open!
    raise FrozenAccountError, "Pòtfèy ou jele — pa ka fè tranzaksyon" if @wallet.held?
    raise FrozenAccountError, "Pòtfèy fèmen" if @wallet.closed?
  end

  def validate_amount!(amount)
    raise InvalidAmountError, "Montan pa valid" unless amount.is_a?(Numeric) && amount > 0
  end
end

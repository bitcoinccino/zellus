class SolEscrowService
  class InsufficientFundsError < StandardError; end
  class FrozenAccountError < StandardError; end

  def initialize(circle)
    @circle = circle
    @escrow = circle.escrow_account || circle.create_escrow_account!
  end

  # Record a member's contribution into escrow
  # Called when a PaymentRequest is paid (HTG or USD)
  def deposit!(user:, round:, asset:, amount:, reference: nil)
    ensure_open!

    ActiveRecord::Base.transaction do
      @escrow.lock!

      new_balance = @escrow.balance_for(asset) + amount
      update_balance!(asset, new_balance)

      @escrow.sol_ledger_entries.create!(
        sol_round: round,
        user: user,
        entry_type: "deposit",
        asset: asset,
        amount: amount,
        balance_after: new_balance,
        reference: reference,
        description: "Kontribisyon #{user.display_name} — Wonn #{round.round_number}"
      )
    end
  end

  # Release payout to the round recipient (net of fees)
  # Called by SolOrchestrator when all members have paid
  def release_payout!(round:)
    ensure_open!

    asset = @circle.asset
    gross = @circle.payout_amount
    platform_fee = @circle.platform_fee_amount
    creator_fee = @circle.creator_fee_amount
    net = @circle.net_payout_amount
    recipient = round.payout_user

    ActiveRecord::Base.transaction do
      @escrow.lock!

      unless @escrow.sufficient_balance?(asset, gross)
        raise InsufficientFundsError,
              "Balans eskwo pa sifi: #{@escrow.balance_for(asset)} #{asset.upcase}, bezwen #{gross}"
      end

      remaining = @escrow.balance_for(asset)

      # 1. Platform fee
      if platform_fee > 0
        remaining -= platform_fee
        @escrow.sol_ledger_entries.create!(
          sol_round: round,
          entry_type: "platform_fee",
          asset: asset,
          amount: platform_fee,
          balance_after: remaining,
          description: "Frè platfòm #{@circle.platform_fee_percent}% — Wonn #{round.round_number}"
        )
      end

      # 2. Creator fee
      if creator_fee > 0 && @circle.user_id != round.payout_user_id
        remaining -= creator_fee
        @escrow.sol_ledger_entries.create!(
          sol_round: round,
          user: @circle.user,
          entry_type: "creator_fee",
          asset: asset,
          amount: creator_fee,
          balance_after: remaining,
          description: "Frè kreyatè #{@circle.creator_fee_percent}% — Wonn #{round.round_number}"
        )
      end

      # 3. Net payout to recipient
      remaining -= net
      @escrow.sol_ledger_entries.create!(
        sol_round: round,
        user: recipient,
        entry_type: "payout",
        asset: asset,
        amount: net,
        balance_after: remaining,
        description: "Peman #{recipient.display_name} — Wonn #{round.round_number}"
      )

      update_balance!(asset, remaining)
    end

    # Return payout breakdown for the orchestrator to send funds
    {
      recipient: recipient,
      net_amount: net,
      platform_fee: platform_fee,
      creator_fee: creator_fee,
      asset: asset
    }
  end

  # Refund a member (e.g., if circle disbands before completion)
  def refund!(user:, round:, asset:, amount:, reason: nil)
    ensure_open!

    ActiveRecord::Base.transaction do
      @escrow.lock!

      unless @escrow.sufficient_balance?(asset, amount)
        raise InsufficientFundsError,
              "Balans eskwo pa sifi pou ranbousman: #{@escrow.balance_for(asset)} #{asset.upcase}"
      end

      new_balance = @escrow.balance_for(asset) - amount
      update_balance!(asset, new_balance)

      @escrow.sol_ledger_entries.create!(
        sol_round: round,
        user: user,
        entry_type: "refund",
        asset: asset,
        amount: amount,
        balance_after: new_balance,
        description: reason || "Ranbousman #{user.display_name}"
      )
    end
  end

  # Hold escrow (e.g., dispute, suspicious activity)
  def hold!
    @escrow.update!(status: :held)
  end

  # Close escrow when circle completes (balance should be 0)
  def close!
    if @escrow.htg_balance > 0 || @escrow.usd_balance > 0
      Rails.logger.warn "SolEscrowService: Fèmen eskwo #{@escrow.id} ak balans rezidyèl " \
                        "HTG=#{@escrow.htg_balance} USD=#{@escrow.usd_balance}"
    end
    @escrow.update!(status: :closed)
  end

  private

  def ensure_open!
    raise FrozenAccountError, "Kont eskwo jele — pa ka fè tranzaksyon" if @escrow.held?
  end

  def update_balance!(asset, new_balance)
    if asset == "htg"
      @escrow.update!(htg_balance: new_balance)
    else
      @escrow.update!(usd_balance: new_balance)
    end
  end
end

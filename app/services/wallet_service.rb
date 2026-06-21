class WalletService
  class InsufficientFundsError < StandardError; end
  class FrozenAccountError < StandardError; end
  class InvalidAmountError < StandardError; end
  class DuplicateDepositError < StandardError; end

  # ── Withdrawal fees (centralized in FeeService) ──

  def self.calculate_instant_fee(amount)
    FeeService.instant_fee(amount)
  end

  def self.calculate_standard_fee(amount)
    FeeService.standard_fee(amount)
  end

  def self.calculate_bank_fee(amount)
    FeeService.bank_withdraw_fee(amount)
  end

  def initialize(wallet)
    @wallet = wallet
  end

  # ── Deposit into wallet (HTG from MonCash, or USD from transfer) ──
  def deposit!(amount:, asset: "htg", moncash_transaction_id: nil, reference: nil, description: nil, skip_limits: false)
    validate_amount!(amount)
    ensure_open!

    # Max balance enforcement for USD deposits (skipped for admin credits)
    if asset == "usd" && !skip_limits
      limit_svc = WalletLimitService.new(@wallet.user)
      if limit_svc.balance_would_exceed?(amount)
        raise InvalidAmountError, "Depo sa a ta depase limit balans ou (#{limit_svc.max_balance.to_i} USD). Balans aktyèl: #{@wallet.usd_balance.to_f.round(2)} USD."
      end
    end

    # Idempotency: prevent double-credit on callback retry
    if moncash_transaction_id.present? &&
       WalletLedgerEntry.exists?(moncash_transaction_id: moncash_transaction_id)
      raise DuplicateDepositError, "Depo sa a deja trete (#{moncash_transaction_id})"
    end

    ActiveRecord::Base.transaction do
      @wallet.lock!

      new_balance = @wallet.balance_for(asset) + amount

      entry = @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "deposit",
        asset: asset,
        amount: amount,
        balance_after: new_balance,
        moncash_transaction_id: moncash_transaction_id,
        reference: reference,
        description: description || "Depo — #{amount} #{asset_label(asset)}"
      )

      update_balance!(asset, entry.balance_after)
    end

    broadcast_balance_update!(asset)
  end

  # ── Withdraw from wallet (debits immediately, worker sends MonCash) ──
  # Fee is subtracted from the entered amount (user receives amount - fee).
  # instant: true → immediate (1.5%, min 25 HTG, max 2,500 HTG)
  # instant: false → standard 48h (1%, min 15 HTG)
  def withdraw!(amount:, asset: "htg", instant: false)
    validate_amount!(amount)
    ensure_open!

    # HTG MonCash withdrawals always have a fee (instant or standard)
    fee = if asset == "htg"
            instant ? self.class.calculate_instant_fee(amount) : self.class.calculate_standard_fee(amount)
    else
            BigDecimal("0")
    end
    payout = amount.to_d - fee  # What user actually receives

    ActiveRecord::Base.transaction do
      @wallet.lock!

      # Total debit is the entered amount (fee included)
      unless @wallet.balance_for(asset) >= amount.to_d
        raise InsufficientFundsError,
              "Balans pa sifi: #{@wallet.balance_for(asset)} #{asset_label(asset)}, bezwen #{amount.to_d} #{asset_label(asset)}"
      end

      running_balance = @wallet.balance_for(asset)

      # 1. Main withdrawal entry (payout — what user receives)
      running_balance -= payout
      withdrawal_entry = @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "withdrawal",
        asset: asset,
        amount: payout,
        balance_after: running_balance,
        description: if asset == "usd"
                       "Retire #{amount.to_d} USD → adrès ekstèn (Base)"
                     elsif instant
                       "Retire instant #{payout.to_i} HTG via MonCash"
                     else
                       "Retire estanda #{payout.to_i} HTG via MonCash (48è)"
                     end
      )

      # 2. Fee entry (instant or standard)
      if fee > 0
        running_balance -= fee
        fee_desc = if instant
                     "Frè retire instant (1.5%, min 25 maks 2,500 HTG)"
        else
                     "Frè retire estanda (1%, min 15 HTG)"
        end
        @wallet.wallet_ledger_entries.create!(
          user: @wallet.user,
          entry_type: instant ? "instant_fee" : "fee",
          asset: asset,
          amount: fee,
          balance_after: running_balance,
          description: fee_desc
        )
      end

      update_balance!(asset, running_balance)
      withdrawal_entry
    end

    broadcast_balance_update!(asset)
  end

  # ── Withdraw from Business account (debits business.total_received or business.usd_balance) ──
  def withdraw_from_business!(business:, amount:, asset: "htg", instant: false)
    validate_amount!(amount)

    fee = if asset == "htg"
            instant ? self.class.calculate_instant_fee(amount) : self.class.calculate_standard_fee(amount)
    else
            BigDecimal("0")
    end
    payout = amount.to_d - fee

    ActiveRecord::Base.transaction do
      business.lock!

      if asset == "htg"
        unless business.sufficient_htg?(amount.to_d)
          raise InsufficientFundsError, "Balans biznis pa sifi"
        end
        business.decrement!(:total_received, amount.to_d)
      else
        unless business.sufficient_usd?(amount.to_d)
          raise InsufficientFundsError, "Balans USD biznis pa sifi"
        end
        business.decrement!(:usd_balance, amount.to_d)
      end

      # Audit trail on user's wallet ledger
      @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "withdrawal",
        asset: asset,
        amount: payout,
        balance_after: @wallet.balance_for(asset),
        description: "Retire #{asset == 'htg' ? "#{payout.to_i} HTG" : "#{amount.to_d} USD"} depi biznis #{business.name}"
      )

      if fee > 0
        @wallet.wallet_ledger_entries.create!(
          user: @wallet.user,
          entry_type: instant ? "instant_fee" : "fee",
          asset: asset,
          amount: fee,
          balance_after: @wallet.balance_for(asset),
          description: "Frè retrè biznis (#{asset == 'htg' ? (instant ? '1.5%' : '1%') : '0'})"
        )
      end
    end
  end

  # ── Bank withdrawal (1% fee, min 25 HTG) ──
  def withdraw_bank!(amount:, fee:)
    validate_amount!(amount)
    ensure_open!

    payout = amount.to_d - fee.to_d

    ActiveRecord::Base.transaction do
      @wallet.lock!

      unless @wallet.balance_for("htg") >= amount.to_d
        raise InsufficientFundsError,
              "Balans pa sifi: #{@wallet.balance_for("htg")} HTG, bezwen #{amount.to_d} HTG"
      end

      running_balance = @wallet.balance_for("htg")

      # 1. Main withdrawal entry
      running_balance -= payout
      withdrawal_entry = @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "withdrawal",
        asset: "htg",
        amount: payout,
        balance_after: running_balance,
        description: "Retire bank #{payout.to_i} HTG → UNIBANK"
      )

      # 2. Bank fee entry
      if fee.to_d > 0
        running_balance -= fee.to_d
        @wallet.wallet_ledger_entries.create!(
          user: @wallet.user,
          entry_type: "fee",
          asset: "htg",
          amount: fee.to_d,
          balance_after: running_balance,
          description: "Frè retire bank (1%, min 25 HTG)"
        )
      end

      update_balance!("htg", running_balance)
      withdrawal_entry
    end

    broadcast_balance_update!("htg")
  end

  # ── Deduct for a Zèllus transfer (sender pays from wallet) ──
  def transfer_out!(amount:, fee:, transfer:, asset: "htg")
    validate_amount!(amount)
    ensure_open!

    ActiveRecord::Base.transaction do
      @wallet.lock!

      unless @wallet.sufficient_balance?(asset, amount)
        raise InsufficientFundsError,
              "Balans pa sifi pou transfè: #{@wallet.balance_for(asset)} #{asset_label(asset)}, bezwen #{amount} #{asset_label(asset)}"
      end

      remaining = @wallet.balance_for(asset)
      net = amount - fee

      # 1. Transfer amount (net of fee)
      remaining -= net
      @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "transfer_out",
        asset: asset,
        amount: net,
        balance_after: remaining,
        reference: transfer,
        description: transfer.business_id? ?
          "Peman Zèllus bay #{transfer.business&.name || transfer.receiver_display}" :
          "Transfè bay #{transfer.receiver_name.presence || transfer.receiver_display}"
      )

      # 2. Fee (separate entry for transparency)
      if fee > 0
        remaining -= fee
        @wallet.wallet_ledger_entries.create!(
          user: @wallet.user,
          entry_type: "fee",
          asset: asset,
          amount: fee,
          balance_after: remaining,
          reference: transfer,
          description: "Frè sèvis — Transfè ##{transfer.id}"
        )
      end

      update_balance!(asset, remaining)
    end

    broadcast_balance_update!(asset)
  end

  # ── Credit receiver's wallet (auto-credit for registered users) ──
  def transfer_in!(amount:, transfer:, sender_user:, asset: "htg")
    validate_amount!(amount)
    ensure_open!

    ActiveRecord::Base.transaction do
      @wallet.lock!

      new_balance = @wallet.balance_for(asset) + amount
      sender_name = sender_user.display_name

      entry = @wallet.wallet_ledger_entries.create!(
        user: sender_user,
        entry_type: "transfer_in",
        asset: asset,
        amount: amount,
        balance_after: new_balance,
        reference: transfer,
        description: transfer.business_id? ?
          "Peman Zèllus de #{sender_name} (#{transfer.business&.name})" :
          "Resevwa #{amount} #{asset_label(asset)} de #{sender_name}"
      )

      update_balance!(asset, entry.balance_after)
    end

    broadcast_balance_update!(asset)
  end

  # ── Refund (failed withdrawal, failed transfer, etc.) ──
  def refund!(amount:, asset: "htg", reference: nil, reason: nil)
    validate_amount!(amount)
    ensure_open!

    ActiveRecord::Base.transaction do
      @wallet.lock!

      new_balance = @wallet.balance_for(asset) + amount

      entry = @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "refund",
        asset: asset,
        amount: amount,
        balance_after: new_balance,
        reference: reference,
        description: reason || "Ranbousman — #{amount} #{asset_label(asset)}"
      )

      update_balance!(asset, entry.balance_after)
    end

    broadcast_balance_update!(asset)
  end

  # ── Convert between any assets (HTG, USD, ETH, wBTC) ──
  CONVERTIBLE_ASSETS = %w[htg usd].freeze
  ASSET_PRECISION = { "htg" => 2, "usd" => 6, "eth" => 8, "wbtc" => 8 }.freeze

  def convert!(amount:, from_asset:, to_asset:, source: "personal", dest: "personal", business: nil)
    from_asset = from_asset.to_s.downcase
    to_asset   = to_asset.to_s.downcase
    validate_amount!(amount)
    ensure_open!
    raise InvalidAmountError, "Menm aktif" if from_asset == to_asset
    raise InvalidAmountError, "Aktif pa valid" unless CONVERTIBLE_ASSETS.include?(from_asset) && CONVERTIBLE_ASSETS.include?(to_asset)

    from_amount = amount.to_d
    from_biz = source == "biznis" && business.present?
    to_biz   = dest == "biznis" && business.present?

    # Convert via USD as common denominator
    usd_value    = asset_to_usd(from_asset, from_amount)
    gross_to     = usd_to_asset(to_asset, usd_value)
    precision    = ASSET_PRECISION.fetch(to_asset, 2)

    # Calculate fee based on HTG equivalent of the conversion
    htg_equivalent = (usd_value * RateService.buy_rate.to_d).round(2)
    fee_rate       = FeeService.crypto_fee_rate(htg_equivalent)
    fee_in_to      = (gross_to * fee_rate).round(precision)
    net_to         = (gross_to - fee_in_to).round(precision)

    raise InvalidAmountError, "Montan twò piti pou konvèti" if net_to <= 0

    ActiveRecord::Base.transaction do
      @wallet.lock!
      business.lock! if business.present? && (from_biz || to_biz)

      # ── Balance check ──
      if from_biz
        col = from_asset == "htg" ? :total_received : :usdc_balance
        unless business.send(col).to_d >= from_amount
          raise InsufficientFundsError, "Balans biznis pa sifi"
        end
      else
        unless @wallet.sufficient_balance?(from_asset, from_amount)
          raise InsufficientFundsError,
                "Balans pa sifi: #{@wallet.balance_for(from_asset)} #{asset_label(from_asset)}, bezwen #{from_amount} #{asset_label(from_asset)}"
        end
      end

      # 1. Debit source
      if from_biz
        biz_col = from_asset == "htg" ? :total_received : :usdc_balance
        business.decrement!(biz_col, from_amount)
        from_remaining = @wallet.balance_for(from_asset)
      else
        from_remaining = @wallet.balance_for(from_asset) - from_amount
      end

      @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "conversion_out",
        asset: from_asset,
        amount: from_amount,
        balance_after: from_remaining,
        source_context: source,
        description: "Konvèti #{from_amount} #{asset_label(from_asset)} → #{net_to} #{asset_label(to_asset)}"
      )

      # 2. Credit destination (net of fee)
      if to_biz
        biz_col = to_asset == "htg" ? :total_received : :usdc_balance
        business.increment!(biz_col, net_to)
        to_remaining = @wallet.balance_for(to_asset)
      else
        to_remaining = @wallet.balance_for(to_asset) + net_to
      end

      @wallet.wallet_ledger_entries.create!(
        user: @wallet.user,
        entry_type: "conversion_in",
        asset: to_asset,
        amount: net_to,
        balance_after: to_remaining,
        source_context: dest,
        description: "Resevwa #{net_to} #{asset_label(to_asset)} (konvèsyon)"
      )

      # 3. Conversion fee entry
      if fee_in_to > 0
        @wallet.wallet_ledger_entries.create!(
          user: @wallet.user,
          entry_type: "conversion_fee",
          asset: to_asset,
          amount: fee_in_to,
          balance_after: to_remaining,
          source_context: dest,
          description: "Frè konvèsyon #{(fee_rate * 100).to_f}% (#{fee_in_to} #{asset_label(to_asset)})"
        )
      end

      # 4. Update personal wallet balances (only if personal account was involved)
      update_balance!(from_asset, from_remaining) unless from_biz
      update_balance!(to_asset, to_remaining) unless to_biz
    end

    broadcast_balance_update!("#{from_asset},#{to_asset}")

    { from: from_amount, to: net_to, fee: fee_in_to, fee_rate: fee_rate }
  end

  private

  # Convert any asset amount to its USD equivalent
  def asset_to_usd(asset, amount)
    case asset
    when "usd" then amount
    when "htg"  then amount / RateService.buy_rate.to_d   # user pays more HTG per USD
    when "eth"  then amount * RateService.eth_usd_rate.to_d
    when "wbtc" then amount * RateService.btc_usd_rate.to_d
    else raise InvalidAmountError, "Aktif pa valid: #{asset}"
    end
  end

  # Convert USD amount to target asset
  def usd_to_asset(asset, usd_amount)
    case asset
    when "usd" then usd_amount
    when "htg"  then usd_amount * RateService.sell_rate.to_d  # user gets fewer HTG per USD
    when "eth"  then usd_amount / RateService.eth_usd_rate.to_d
    when "wbtc" then usd_amount / RateService.btc_usd_rate.to_d
    else raise InvalidAmountError, "Aktif pa valid: #{asset}"
    end
  end

  public

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

  # ── Multi-asset balance update (mirrors SolEscrowService) ──
  def update_balance!(asset, new_balance)
    col = "#{asset}_balance"
    @wallet.update!(col => new_balance)
  end

  def asset_label(asset)
    asset.to_s == "usd" ? "USD" : asset.to_s.upcase
  end

  # ── Broadcast updated balances via ActionCable (live wallet updates) ──
  def broadcast_balance_update!(asset_changed = nil)
    user = @wallet.user
    @wallet.reload

    ::NotificationChannel.broadcast_to(user, {
      type: "balance_update",
      balances: {
        htg:  @wallet.htg_balance.to_f.round(2),
        usd: @wallet.usd_balance.to_f.round(2),
        eth:  @wallet.eth_balance.to_f.round(6),
        wbtc: @wallet.wbtc_balance.to_f.round(8)
      },
      asset_changed: asset_changed.to_s
    })
  rescue => e
    Rails.logger.error "[WalletService] Balance broadcast error: #{e.message}"
  end
end

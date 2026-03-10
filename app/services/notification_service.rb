class NotificationService
  class << self
    # ── Transfer: receiver gets money ──
    def transfer_received(transfer)
      receiver = find_receiver_user(transfer)
      return unless receiver

      sender_name = transfer.user&.display_name || "Yon moun"
      amount_label = format_transfer_amount(transfer)

      create_notification(
        user: receiver,
        actor: transfer.user,
        notifiable: transfer,
        notification_type: "transfer_received",
        title: "#{sender_name} voye ou #{amount_label}",
        body: transfer.note
      )
    end

    # ── Transfer: sender's transfer completed ──
    def transfer_completed(transfer)
      return unless transfer.user

      receiver_label = transfer.receiver_cashtag.present? ? "$#{transfer.receiver_cashtag}" : (transfer.receiver_name.presence || transfer.receiver_display)
      amount_label = format_transfer_amount(transfer)

      create_notification(
        user: transfer.user,
        notifiable: transfer,
        notification_type: "transfer_completed",
        title: "Transfè #{amount_label} bay #{receiver_label} konplete"
      )
    end

    # ── Transfer: sender's transfer failed ──
    def transfer_failed(transfer)
      return unless transfer.user

      amount_label = format_transfer_amount(transfer)

      create_notification(
        user: transfer.user,
        notifiable: transfer,
        notification_type: "transfer_failed",
        title: "Transfè #{amount_label} echwe",
        body: transfer.failure_reason
      )
    end

    # ── Payment request: payer receives a request ──
    def payment_request_received(payment_request)
      return unless payment_request.payer_id

      payer = User.find_by(id: payment_request.payer_id)
      return unless payer

      sender_name = payment_request.user&.display_name || "Yon moun"
      amount_label = format_pr_amount(payment_request)

      create_notification(
        user: payer,
        actor: payment_request.user,
        notifiable: payment_request,
        notification_type: "payment_request_received",
        title: "#{sender_name} mande ou #{amount_label}"
      )
    end

    # ── Payment request: creator gets paid ──
    def payment_request_paid(payment_request)
      return unless payment_request.user

      payer = User.find_by(id: payment_request.payer_id)
      payer_name = payer&.display_name || "Yon moun"
      amount_label = format_pr_amount(payment_request)

      create_notification(
        user: payment_request.user,
        actor: payer,
        notifiable: payment_request,
        notification_type: "payment_request_paid",
        title: "#{payer_name} peye demann #{amount_label} ou"
      )
    end

    # ── Crypto deposit: external wallet sends funds ──
    def crypto_deposit_received(user, amount, asset, tx_hash)
      return unless user

      asset_label = asset.to_s.downcase
      amount_display = case asset_label
                       when "eth"  then "#{format('%.6f', amount.to_f)} ETH"
                       when "wbtc" then "#{format('%.8f', amount.to_f)} WBTC"
                       when "usdc" then "#{format('%.2f', amount.to_f)} USD"
                       else "#{amount.to_i} HTG"
                       end

      create_notification(
        user: user,
        notification_type: "transfer_received",
        title: "Ou resevwa #{amount_display} nan pòtfèy ou",
        body: "Depo kripto konfime sou Base (tx: #{tx_hash.first(10)}…)"
      )
    end

    # ── Crypto withdrawal: failed and refunded ──
    def crypto_withdrawal_failed(user, amount, asset, reason)
      return unless user

      asset_label = asset.to_s.downcase
      amount_display = case asset_label
                       when "eth"  then "#{format('%.6f', amount.to_f)} ETH"
                       when "wbtc" then "#{format('%.8f', amount.to_f)} WBTC"
                       when "usdc" then "#{format('%.2f', amount.to_f)} USD"
                       else "#{amount.to_i} HTG"
                       end

      create_notification(
        user: user,
        notification_type: "transfer_failed",
        title: "Retrè #{amount_display} echwe — lajan ranbouse",
        body: reason
      )
    end

    # ── Crypto withdrawal: sent successfully ──
    def crypto_withdrawal_sent(user, amount, asset, tx_hash)
      return unless user

      asset_label = asset.to_s.downcase
      amount_display = case asset_label
                       when "eth"  then "#{format('%.6f', amount.to_f)} ETH"
                       when "wbtc" then "#{format('%.8f', amount.to_f)} WBTC"
                       when "usdc" then "#{format('%.2f', amount.to_f)} USD"
                       else "#{amount.to_i} HTG"
                       end

      create_notification(
        user: user,
        notification_type: "transfer_completed",
        title: "Retrè #{amount_display} voye sou Base",
        body: "Tranzaksyon: #{tx_hash.first(10)}…"
      )
    end

    # ── HTG deposit confirmed ──
    def deposit_confirmed(user, amount)
      return unless user

      create_notification(
        user: user,
        notification_type: "transfer_received",
        title: "Depo #{amount.to_i} HTG reyisi"
      )
    end

    # ── Withdrawal sent (MonCash / bank / stock) ──
    def withdrawal_sent(user, amount, method_label)
      return unless user

      display = amount.is_a?(BigDecimal) && amount < 1 ? amount.to_s("F") : amount.to_i.to_s
      create_notification(
        user: user,
        notification_type: "transfer_completed",
        title: "Retrè #{display} voye via #{method_label}"
      )
    end

    # ── Withdrawal failed + refunded ──
    def withdrawal_failed(user, amount, reason)
      return unless user

      create_notification(
        user: user,
        notification_type: "transfer_failed",
        title: "Retrè #{amount.to_i} HTG echwe — lajan ranbouse",
        body: reason.to_s.truncate(100)
      )
    end

    # ── Crypto buy/sell completed ──
    def transaction_completed(transaction)
      return unless transaction&.user

      label = transaction.buy? ? "Acha" : "Vann"
      crypto_display = "#{transaction.crypto_amount} #{transaction.crypto_currency.upcase}"
      title = if transaction.sell? || transaction.loan_request?
                "#{label} #{crypto_display} konplete — #{transaction.fiat_amount.to_i} HTG voye"
              else
                "#{label} #{crypto_display} konplete"
              end

      create_notification(
        user: transaction.user,
        notifiable: transaction,
        notification_type: "transfer_completed",
        title: title
      )
    end

    # ── Crypto buy/sell failed ──
    def transaction_failed(transaction)
      return unless transaction&.user

      label = transaction.buy? ? "Acha" : "Vann"
      crypto_display = "#{transaction.crypto_amount} #{transaction.crypto_currency.upcase}"

      create_notification(
        user: transaction.user,
        notifiable: transaction,
        notification_type: "transfer_failed",
        title: "#{label} #{crypto_display} echwe",
        body: transaction.failure_reason.to_s.truncate(100)
      )
    end

    # ── Conversion completed ──
    def conversion_completed(user, from_amount, from_asset, to_amount, to_asset)
      return unless user

      create_notification(
        user: user,
        notification_type: "transfer_completed",
        title: "Konvèti #{from_amount} #{from_asset == 'usdc' ? 'USD' : from_asset.upcase} → #{to_amount} #{to_asset == 'usdc' ? 'USD' : to_asset.upcase} reyisi"
      )
    end

    # ── Payment request: canceled by creator ──
    def payment_request_canceled(payment_request)
      return unless payment_request.payer_id

      payer = User.find_by(id: payment_request.payer_id)
      return unless payer

      creator_name = payment_request.user&.display_name || "Yon moun"
      amount_label = format_pr_amount(payment_request)

      create_notification(
        user: payer,
        actor: payment_request.user,
        notifiable: payment_request,
        notification_type: "payment_request_canceled",
        title: "#{creator_name} anile demann #{amount_label}",
        body: payment_request.cancel_note
      )
    end

    # ── Payment request: expired ──
    def payment_request_expired(payment_request)
      return unless payment_request.user

      amount_label = format_pr_amount(payment_request)

      create_notification(
        user: payment_request.user,
        notifiable: payment_request,
        notification_type: "payment_request_expired",
        title: "Demann #{amount_label} ekspire"
      )
    end

    private

    def create_notification(attrs)
      notif = Notification.create!(attrs)
      broadcast_notification(notif, attrs)
      notif
    rescue => e
      Rails.logger.error "NotificationService: failed to create notification [#{attrs[:notification_type]}]: #{e.message}"
    end

    SOUND_TYPES = %w[transfer_received transfer_completed payment_request_paid].freeze

    def broadcast_notification(notification, attrs)
      ::NotificationChannel.broadcast_to(
        notification.user,
        {
          title: attrs[:title],
          type: attrs[:notification_type],
          play_sound: SOUND_TYPES.include?(attrs[:notification_type]),
          unread_count: notification.user.notifications.unread.count
        }
      )
    rescue => e
      Rails.logger.error "NotificationService broadcast error: #{e.message}"
    end

    def find_receiver_user(transfer)
      if transfer.receiver_cashtag.present?
        user = User.find_by("LOWER(cashtag) = ?", transfer.receiver_cashtag.downcase)
        return user if user && user.id != transfer.user_id
      end

      if transfer.receiver_email.present?
        user = User.find_by(email: transfer.receiver_email)
        return user if user && user.id != transfer.user_id
      end

      if transfer.receiver_phone.present?
        user = User.find_by(phone_number: transfer.receiver_phone)
        return user if user && user.id != transfer.user_id
      end

      nil
    end

    def format_transfer_amount(transfer)
      if transfer.usdc_wallet_transfer?
        "#{transfer.crypto_amount || transfer.net_amount} USD"
      elsif transfer.crypto_transfer? && transfer.crypto_amount.present?
        "#{transfer.crypto_amount} #{transfer.asset_label}"
      else
        "#{transfer.amount.to_i} HTG"
      end
    end

    def format_pr_amount(pr)
      if pr.htg?
        "#{pr.amount.to_i} HTG"
      else
        "#{pr.amount} #{pr.asset.upcase}"
      end
    end
  end
end

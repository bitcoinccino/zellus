class NotificationService
  class << self
    # ── Transfer: receiver gets money ──
    # skip_sound: true when the controller already sent a real-time broadcast
    # with play_sound — avoids double chime while still creating the DB record.
    def transfer_received(transfer, skip_sound: false)
      receiver = find_receiver_user(transfer)
      return unless receiver

      sender_label = if transfer.business.present?
                       transfer.business.name
      elsif transfer.user&.cashtag.present?
                       "$#{transfer.user.cashtag}"
      else
                       transfer.user&.display_name || "Yon moun"
      end
      amount_label = format_transfer_amount(transfer)

      create_notification(
        skip_sound: skip_sound,
        user: receiver,
        actor: transfer.user,
        notifiable: transfer,
        notification_type: "transfer_received",
        title: "#{sender_label} peye w #{amount_label} la",
        body: transfer.note
      )
    end

    # ── Thanks: receiver says thanks to sender ──
    def thanks_received(transfer:, thanker:, recipient:)
      thanker_label = if transfer.business.present?
                        transfer.business.name
      elsif thanker.cashtag.present?
                        "$#{thanker.cashtag}"
      else
                        thanker.display_name || "Yon moun"
      end

      amount_str = format_transfer_amount(transfer)

      create_notification(
        user: recipient,
        actor: thanker,
        notifiable: transfer,
        notification_type: "thanks_received",
        title: "#{thanker_label} di ou mèsi pou #{amount_str} la",
        skip_sound: true
      )
    end

    # ── Transfer: sender's transfer completed ──
    def transfer_completed(transfer)
      return unless transfer.user

      receiver_label = transfer.receiver_cashtag.present? ? "$#{transfer.receiver_cashtag}" : (transfer.receiver_name.presence || transfer.receiver_display)
      biz_label  = transfer.business.present? ? " via #{transfer.business.name}" : ""
      amount_label = format_transfer_amount(transfer)

      create_notification(
        user: transfer.user,
        actor: transfer.user,
        notifiable: transfer,
        notification_type: "transfer_completed",
        title: "Ou peye #{receiver_label} ~ #{amount_label}#{biz_label}"
      )
    end

    # ── Transfer: sender's transfer failed ──
    def transfer_failed(transfer)
      return unless transfer.user

      amount_label = format_transfer_amount(transfer)

      create_notification(
        user: transfer.user,
        actor: transfer.user,
        notifiable: transfer,
        notification_type: "transfer_failed",
        title: "Peman #{amount_label} echwe",
        body: friendly_failure_reason(transfer.failure_reason)
      )
    end

    # ── Payment request: payer receives a request ──
    def payment_request_received(payment_request)
      return unless payment_request.payer_id

      payer = User.find_by(id: payment_request.payer_id)
      return unless payer

      sender_tag = payment_request.user&.cashtag.present? ? "$#{payment_request.user.cashtag}" : (payment_request.user&.display_name || "Yon moun")
      amount_label = format_pr_amount(payment_request)

      create_notification(
        user: payer,
        actor: payment_request.user,
        notifiable: payment_request,
        notification_type: "payment_request_received",
        title: "#{sender_tag} mande w #{amount_label}"
      )
    end

    # ── Payment request: creator gets paid ──
    def payment_request_paid(payment_request)
      return unless payment_request.user

      payer = User.find_by(id: payment_request.payer_id)
      payer_tag = payer&.cashtag.present? ? "$#{payer.cashtag}" : (payer&.display_name || "Yon moun")
      amount_label = format_pr_amount(payment_request)

      create_notification(
        user: payment_request.user,
        actor: payer,
        notifiable: payment_request,
        notification_type: "payment_request_paid",
        title: "#{payer_tag} peye demann #{amount_label}"
      )
    end

    # ── Crypto deposit: external wallet sends funds ──
    def crypto_deposit_received(user, amount, asset, tx_hash)
      return unless user

      asset_label = asset.to_s.downcase
      amount_display = case asset_label
      when "eth"  then "#{format('%.6f', amount.to_f)} ETH"
      when "wbtc" then "#{format('%.8f', amount.to_f)} WBTC"
      when "usd" then "#{format('%.2f', amount.to_f)} USD"
      else "#{amount.to_i} HTG"
      end

      create_notification(
        user: user,
        notification_type: "deposit_confirmed",
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
      when "usd" then "#{format('%.2f', amount.to_f)} USD"
      else "#{amount.to_i} HTG"
      end

      create_notification(
        user: user,
        notification_type: "withdrawal_failed",
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
      when "usd" then "#{format('%.2f', amount.to_f)} USD"
      else "#{amount.to_i} HTG"
      end

      create_notification(
        user: user,
        notification_type: "withdrawal_sent",
        title: "Retrè #{amount_display} voye sou Base",
        body: "Tranzaksyon: #{tx_hash.first(10)}…"
      )
    end

    # ── UMA: inbound remittance received via Lightspark Grid ──
    def uma_payment_received(user, amount, asset, sender_uma)
      return unless user

      asset_label = asset.to_s.downcase == "usd" ? "USD" : asset.to_s.upcase
      amount_display = asset_label == "USD" ? "#{'%.2f' % amount.to_f} USD" : "#{amount.to_i} HTG"
      sender_display = sender_uma.present? ? sender_uma : "UMA"

      create_notification(
        user: user,
        notification_type: "transfer_received",
        title: "Ou resevwa #{amount_display} de #{sender_display}",
        body: "Peman UMA entènasyonal rive nan pòtfèy ou"
      )
    end

    # ── HTG deposit confirmed ──
    def deposit_confirmed(user, amount)
      return unless user

      create_notification(
        user: user,
        notification_type: "deposit_confirmed",
        title: "Ou depoze #{amount.to_i} HTG sou kont pèsonèl"
      )
    end

    # ── Withdrawal sent (MonCash / bank / stock) ──
    def withdrawal_sent(user, amount, method_label)
      return unless user

      display = amount.is_a?(BigDecimal) && amount < 1 ? amount.to_s("F") : amount.to_i.to_s
      create_notification(
        user: user,
        notification_type: "withdrawal_sent",
        title: "Ou retire #{display} sou kont pèsonèl"
      )
    end

    # ── Withdrawal failed + refunded ──
    def withdrawal_failed(user, amount, reason)
      return unless user

      create_notification(
        user: user,
        notification_type: "withdrawal_failed",
        title: "Retrè #{amount.to_i} HTG echwe — lajan ranbouse",
        body: reason.to_s.truncate(100)
      )
    end

    # ── Crypto buy/sell completed ──
    def transaction_completed(transaction)
      return unless transaction&.user

      crypto_display = "#{transaction.crypto_amount} #{transaction.crypto_currency&.upcase == 'USD' ? 'USD' : transaction.crypto_currency&.upcase}"
      title = if transaction.buy?
                "Ou achte #{crypto_display} ak #{transaction.fiat_amount.to_i} HTG"
      else
                "Ou vann #{crypto_display} → #{transaction.fiat_amount.to_i} HTG"
      end

      create_notification(
        user: transaction.user,
        notifiable: transaction,
        notification_type: transaction.buy? ? "buy_completed" : "sell_completed",
        title: title
      )
    end

    # ── Crypto buy/sell failed ──
    def transaction_failed(transaction)
      return unless transaction&.user

      label = transaction.buy? ? "Acha" : "Vann"
      crypto_display = "#{transaction.crypto_amount} #{transaction.crypto_currency&.upcase == 'USD' ? 'USD' : transaction.crypto_currency&.upcase}"

      create_notification(
        user: transaction.user,
        notifiable: transaction,
        notification_type: "buy_failed",
        title: "#{label} #{crypto_display} echwe",
        body: transaction.failure_reason.to_s.truncate(100)
      )
    end

    # ── Conversion completed ──
    def conversion_completed(user, from_amount, from_asset, to_amount, to_asset)
      return unless user

      from_label = from_asset == "usd" ? "USD" : from_asset.upcase
      to_label = to_asset == "usd" ? "USD" : to_asset.upcase
      create_notification(
        user: user,
        notification_type: "conversion_completed",
        title: "Ou konvèti #{from_amount} #{from_label} pou #{to_amount} #{to_label}"
      )
    end

    # ── Payment request: canceled by creator ──
    def payment_request_canceled(payment_request)
      return unless payment_request.payer_id

      payer = User.find_by(id: payment_request.payer_id)
      return unless payer

      creator_tag = payment_request.user&.cashtag.present? ? "$#{payment_request.user.cashtag}" : (payment_request.user&.display_name || "Yon moun")
      amount_label = format_pr_amount(payment_request)

      create_notification(
        user: payer,
        actor: payment_request.user,
        notifiable: payment_request,
        notification_type: "payment_request_canceled",
        title: "#{creator_tag} anile demann #{amount_label}",
        body: payment_request.cancel_note
      )
    end

    # ── Payment request: declined by payer ──
    def payment_request_declined(payment_request, decliner)
      creator = payment_request.user
      return unless creator

      decliner_tag = decliner.cashtag.present? ? "$#{decliner.cashtag}" : decliner.display_name
      amount_label = format_pr_amount(payment_request)

      create_notification(
        user: creator,
        actor: decliner,
        notifiable: payment_request,
        notification_type: "payment_request_declined",
        title: "#{decliner_tag} refize demann #{amount_label}",
        body: payment_request.cancel_note
      )
    end

    # ── Agent: customer receives cash-in deposit ──
    def agent_cash_in_received(agent_tx)
      return unless agent_tx.customer

      agent_name = agent_tx.business.name
      amount = agent_tx.amount.to_i
      code = agent_tx.confirmation_code

      create_notification(
        user: agent_tx.customer,
        notifiable: agent_tx,
        notification_type: "transfer_received",
        title: "Ou resevwa #{amount} HTG nan men #{agent_name}",
        body: "Kòd konfimasyon ou se: #{code}"
      )
    end

    # ── Agent: agent gets confirmation of completed cash-in ──
    def agent_cash_in_completed(agent_tx)
      return unless agent_tx.business.user

      customer_tag = "$#{agent_tx.customer.cashtag}"
      amount = agent_tx.amount.to_i
      commission = agent_tx.commission_amount.to_i

      create_notification(
        user: agent_tx.business.user,
        notifiable: agent_tx,
        notification_type: "transfer_completed",
        title: "Depo #{amount} HTG bay #{customer_tag} konplete",
        body: "Komisyon: +#{commission} HTG · Kòd: #{agent_tx.confirmation_code}"
      )
    end

    # ── Agent Application: Approved ──
    def agent_application_approved(business)
      return unless business.user

      create_notification(
        user: business.user,
        notifiable: business,
        notification_type: "transfer_completed",
        title: "Felisitasyon! #{business.name} apwouve kòm ajan Zèllus!",
        body: "Ou ka kounye a fè depo lajan kach pou kliyan. Komisyon ou se #{(business.agent_commission_rate * 100).round(1)}%."
      )
    end

    # ── Agent: Suspended ──
    def agent_suspended(business, reason)
      return unless business.user

      create_notification(
        user: business.user,
        notifiable: business,
        notification_type: "transfer_failed",
        title: "Kont ajan #{business.name} sispann",
        body: "Rezon: #{reason}. Kontakte sipò pou plis enfòmasyon."
      )
    end

    # ── Agent: Reactivated ──
    def agent_reactivated(business)
      return unless business.user

      create_notification(
        user: business.user,
        notifiable: business,
        notification_type: "transfer_completed",
        title: "Kont ajan #{business.name} reaktive!",
        body: "Kont ajan ou aktif ankò. Ou ka rekòmanse fè tranzaksyon."
      )
    end

    # ── Agent Application: Rejected ──
    def agent_application_rejected(business, reason)
      return unless business.user

      create_notification(
        user: business.user,
        notifiable: business,
        notification_type: "transfer_failed",
        title: "Aplikasyon ajan #{business.name} pa apwouve",
        body: "Rezon: #{reason}. Ou ka aplike ankò lè ou korije pwoblèm nan."
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

    def create_notification(skip_sound: false, **attrs)
      notif = Notification.create!(attrs)
      broadcast_notification(notif, attrs, skip_sound: skip_sound)
      notif
    rescue => e
      Rails.logger.error "NotificationService: failed to create notification [#{attrs[:notification_type]}]: #{e.message}"
    end

    SOUND_TYPES = %w[transfer_received].freeze

    def broadcast_notification(notification, attrs, skip_sound: false)
      # Include sender avatar in the broadcast for toast display
      avatar_url = nil
      if notification.actor.present?
        if notification.actor.avatar.attached?
          avatar_url = Rails.application.routes.url_helpers.rails_blob_url(notification.actor.avatar, only_path: true)
        elsif notification.actor.bonid_photo_url.present?
          avatar_url = notification.actor.bonid_photo_url
        end
      end

      should_play = !skip_sound && SOUND_TYPES.include?(attrs[:notification_type])

      ::NotificationChannel.broadcast_to(
        notification.user,
        {
          title: attrs[:title],
          type: attrs[:notification_type],
          play_sound: should_play,
          unread_count: notification.user.notifications.unread.count,
          avatar_url: avatar_url
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
      if transfer.usd_wallet_transfer?
        amt = transfer.crypto_amount || transfer.net_amount
        "#{'%.2f' % amt} USD"
      elsif transfer.crypto_transfer? && transfer.crypto_amount.present?
        "#{'%.2f' % transfer.crypto_amount} #{transfer.asset_label}"
      else
        "#{transfer.amount.to_i} HTG"
      end
    end

    def format_pr_amount(pr)
      if pr.htg?
        "#{pr.amount.to_i} HTG"
      else
        "#{'%.2f' % pr.amount} #{pr.asset_label}"
      end
    end

    def friendly_failure_reason(reason)
      return "Erè enkoni." if reason.blank?
      r = reason.to_s.downcase
      if r.include?("transfer amount exceeds balance") || r.include?("insufficient")
        "Trezò pa gen ase USD pou trete transfè sa a."
      elsif r.include?("nonce too low") || r.include?("nonce already used")
        "Erè rezo — tranzaksyon an te deja trete."
      elsif r.include?("gas") && r.include?("exceed")
        "Frè rezo twò wo pou trete transfè sa a kounye a."
      elsif r.include?("timeout") || r.include?("timed out")
        "Koneksyon ak rezo Base te ekspire."
      elsif r.include?("reverted") || r.include?("revert")
        "Tranzaksyon an pa t kapab konplete sou rezo Base."
      elsif r.include?("consent") || r.include?("bonid")
        "Verifikasyon BonID obligatwa pou montan sa a."
      else
        "Transfè pa t kapab konplete. Kontakte sipò si pwoblèm nan pèsiste."
      end
    end
  end
end

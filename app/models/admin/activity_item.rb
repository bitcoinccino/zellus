module Admin
  class ActivityItem
    attr_reader :id, :activity_type, :type_label, :type_icon, :type_bg, :type_color,
                :user, :amount_htg, :amount_usd, :status_key, :status_label,
                :status_bg, :status_color, :status_icon, :created_at, :record,
                :secondary_label, :reference

    def initialize(attrs = {})
      attrs.each { |k, v| instance_variable_set("@#{k}", v) }
    end

    # ── Factory: Transaction ──
    def self.from_transaction(tx, usd_htg_rate: 135.50)
      type_conf = case tx.transaction_type
                  when "buy"          then { label: "Achte",  icon: "ri-arrow-down-circle-line", bg: "#dcfce7", color: "#166534" }
                  when "sell"         then { label: "Vann",   icon: "ri-arrow-up-circle-line",   bg: "#dbeafe", color: "#1d4ed8" }
                  when "loan_request" then { label: "Prè",    icon: "ri-hand-coin-line",         bg: "#fef3c7", color: "#92400e" }
                  else                     { label: tx.transaction_type.to_s.humanize, icon: "ri-exchange-line", bg: "rgba(93,99,69,0.1)", color: "var(--haiti-olive)" }
                  end

      status_conf = status_for_transaction(tx.status)
      htg = tx.fiat_amount.to_f
      usd = usd_htg_rate > 0 ? (htg / usd_htg_rate).round(2) : 0

      new(
        id: tx.id,
        activity_type: "transaction",
        type_label: type_conf[:label],
        type_icon: type_conf[:icon],
        type_bg: type_conf[:bg],
        type_color: type_conf[:color],
        user: tx.user,
        amount_htg: htg,
        amount_usd: usd,
        status_key: tx.status,
        status_label: status_conf[:label],
        status_bg: status_conf[:bg],
        status_color: status_conf[:color],
        status_icon: status_conf[:icon],
        created_at: tx.created_at,
        record: tx,
        secondary_label: tx.crypto_currency&.upcase,
        reference: tx.token
      )
    end

    # ── Factory: Transfer ──
    def self.from_transfer(t, usd_htg_rate: 135.50)
      status_conf = status_for_transfer(t.status)
      htg = t.amount.to_f
      usd = usd_htg_rate > 0 ? (htg / usd_htg_rate).round(2) : 0

      new(
        id: t.id,
        activity_type: "transfer",
        type_label: "Transfè",
        type_icon: "ri-send-plane-line",
        type_bg: "#f3e8ff",
        type_color: "#7c3aed",
        user: t.user,
        amount_htg: htg,
        amount_usd: usd,
        status_key: t.status,
        status_label: status_conf[:label],
        status_bg: status_conf[:bg],
        status_color: status_conf[:color],
        status_icon: status_conf[:icon],
        created_at: t.created_at,
        record: t,
        secondary_label: "→ #{t.receiver_display}",
        reference: t.token
      )
    end

    # ── Factory: BankWithdrawal ──
    def self.from_bank_withdrawal(bw, usd_htg_rate: 135.50)
      status_conf = status_for_bank_withdrawal(bw.status)
      htg = bw.amount.to_f
      usd = usd_htg_rate > 0 ? (htg / usd_htg_rate).round(2) : 0

      new(
        id: bw.id,
        activity_type: "bank_withdrawal",
        type_label: "Retrè Bank",
        type_icon: "ri-bank-line",
        type_bg: "#fef3c7",
        type_color: "#92400e",
        user: bw.user,
        amount_htg: htg,
        amount_usd: usd,
        status_key: bw.status,
        status_label: status_conf[:label],
        status_bg: status_conf[:bg],
        status_color: status_conf[:color],
        status_icon: status_conf[:icon],
        created_at: bw.created_at,
        record: bw,
        secondary_label: "#{bw.bank_name} · #{bw.masked_account}",
        reference: bw.id.to_s
      )
    end

    # ── Status maps ──
    def self.status_for_transaction(status)
      case status.to_s
      when "completed"     then { label: "Konplè",       bg: "#5C6B24", color: "#ffffff", icon: "ri-check-line" }
      when "crypto_sent"   then { label: "Voye",          bg: "#1d4ed8", color: "#ffffff", icon: "ri-send-plane-line" }
      when "paid"          then { label: "Peye",          bg: "#E9B44C", color: "#ffffff", icon: "ri-time-line" }
      when "pending"       then { label: "An Atant",      bg: "#E9B44C", color: "#ffffff", icon: "ri-time-line" }
      when "payout_failed" then { label: "Peman Echwe",   bg: "#D21034", color: "#ffffff", icon: "ri-error-warning-line" }
      when "failed"        then { label: "Echwe",         bg: "#D21034", color: "#ffffff", icon: "ri-close-circle-line" }
      else                      { label: status.to_s.humanize, bg: "#E9B44C", color: "#ffffff", icon: "ri-question-line" }
      end
    end

    def self.status_for_transfer(status)
      case status.to_s
      when "completed"         then { label: "Konplè",      bg: "#5C6B24", color: "#ffffff", icon: "ri-check-line" }
      when "claimed"           then { label: "Reklame",      bg: "#1d4ed8", color: "#ffffff", icon: "ri-hand-heart-line" }
      when "sent"              then { label: "Voye",         bg: "#1d4ed8", color: "#ffffff", icon: "ri-send-plane-line" }
      when "funded"            then { label: "Finanse",      bg: "#0891b2", color: "#ffffff", icon: "ri-money-dollar-circle-line" }
      when "awaiting_consent"  then { label: "Ap Tann",      bg: "#E9B44C", color: "#ffffff", icon: "ri-time-line" }
      when "pending"           then { label: "An Atant",     bg: "#E9B44C", color: "#ffffff", icon: "ri-time-line" }
      when "expired"           then { label: "Ekspire",      bg: "#D21034", color: "#ffffff", icon: "ri-time-line" }
      when "refunded"          then { label: "Ranbouse",     bg: "#7c3aed", color: "#ffffff", icon: "ri-refund-line" }
      when "failed"            then { label: "Echwe",        bg: "#D21034", color: "#ffffff", icon: "ri-close-circle-line" }
      else                          { label: status.to_s.humanize, bg: "#E9B44C", color: "#ffffff", icon: "ri-question-line" }
      end
    end

    def self.status_for_bank_withdrawal(status)
      case status.to_s
      when "completed"  then { label: "Fini",      bg: "#5C6B24", color: "#ffffff", icon: "ri-check-line" }
      when "processing" then { label: "Ap Trete",  bg: "#1d4ed8", color: "#ffffff", icon: "ri-loader-4-line" }
      when "pending"    then { label: "An Atant",   bg: "#E9B44C", color: "#ffffff", icon: "ri-time-line" }
      when "failed"     then { label: "Echwe",      bg: "#D21034", color: "#ffffff", icon: "ri-close-circle-line" }
      else                   { label: status.to_s.humanize, bg: "#E9B44C", color: "#ffffff", icon: "ri-question-line" }
      end
    end
  end
end

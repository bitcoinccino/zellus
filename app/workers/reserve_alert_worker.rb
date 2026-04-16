# frozen_string_literal: true
require 'sidekiq'

# Periodically checks platform liquidity reserves (admin USDC + HTG balances).
# Sends an email alert to ADMIN_EMAIL when either drops below the warning
# threshold (25% above the hard pause minimum) so you can top up before
# users get blocked.
#
# Throttled to one alert per asset per 6 hours so we don't spam.
class ReserveAlertWorker
  include Sidekiq::Job

  POLL_INTERVAL = 30.minutes
  ALERT_COOLDOWN = 6.hours

  def perform
    health = WalletLimitService.platform_health

    [:usdc, :htg].each do |asset|
      next unless health[asset][:alert]

      cache_key = "reserve_alert_sent:#{asset}"
      last_sent_at = Rails.cache.read(cache_key)
      next if last_sent_at && last_sent_at > ALERT_COOLDOWN.ago

      send_alert(asset, health[asset])
      Rails.cache.write(cache_key, Time.current, expires_in: ALERT_COOLDOWN)
    end
  rescue => e
    Rails.logger.error "ReserveAlertWorker error: #{e.class}: #{e.message}"
  ensure
    self.class.perform_in(POLL_INTERVAL)
  end

  private

  def send_alert(asset, status)
    admin_email = ENV["ADMIN_EMAIL"].to_s.strip
    return if admin_email.blank?

    asset_label = asset == :usdc ? "USDC" : "HTG"
    reserve_str = asset == :usdc ? "$#{status[:reserve].to_f.round(2)}" : "#{status[:reserve].to_f.round(0)} HTG"
    minimum_str = asset == :usdc ? "$#{status[:minimum].to_f.round(0)}" : "#{status[:minimum].to_f.round(0)} HTG"
    severity = status[:paused] ? "🚨 PAUSED" : "⚠️  LOW"

    subject = "[Zèllus] #{severity}: #{asset_label} reserve at #{reserve_str}"
    body = <<~MSG
      Platform #{asset_label} reserve is below the warning threshold.

      Current reserve: #{reserve_str}
      Hard-pause minimum: #{minimum_str}
      Status: #{status[:paused] ? "OPERATIONS PAUSED" : "Approaching pause threshold"}

      Top up the admin wallet to restore service.
    MSG

    Rails.logger.warn "[ReserveAlert] #{subject}"

    begin
      ActionMailer::Base.mail(
        to: admin_email,
        from: "alerts@zellus.app",
        subject: subject,
        body: body
      ).deliver_now
      Rails.logger.info "[ReserveAlert] Email sent to #{admin_email}"
    rescue => e
      Rails.logger.error "[ReserveAlert] Email send failed: #{e.message}"
    end
  end
end

# Warn at boot if BonID OAuth is configured but unreachable.
# Prevents silent failures where users click "Konekte ak BonID"
# and get redirected to a broken URL.
Rails.application.config.after_initialize do
  next unless ENV["BONID_OAUTH_CLIENT_ID"].present? && ENV["BONID_BASE_URL"].present?
  next if Rails.env.test?

  Thread.new do
    begin
      require "net/http"
      base = ENV["BONID_BASE_URL"].sub(%r{/api/v1\z}, "")
      uri = URI("#{base}/oauth/applications/#{ENV['BONID_OAUTH_CLIENT_ID']}")
      response = Net::HTTP.get_response(uri)

      if response.code == "404"
        Rails.logger.warn "⚠️  BONID WARNING: OAuth application #{ENV['BONID_OAUTH_CLIENT_ID']} not found on BonID server. " \
                          "Users will not be able to sign in via BonID. " \
                          "Create the OAuth app in BonID's database: rails console → OauthApplication.create!(...)"
      end
    rescue => e
      Rails.logger.warn "⚠️  BONID WARNING: Could not reach BonID server (#{e.message}). BonID login may not work."
    end
  end
end

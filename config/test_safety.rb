# Tests must never be able to move real money or call real services. A test
# once broadcast a real treasury transfer because .env was loaded into the test
# process. Required from config/application.rb before the app is defined, so
# initializers that copy keys into constants (CircleConfig, LightsparkConfig)
# never see them. Covered by test/test_safety_test.rb.
module TestSafety
  SECRET_VARIABLES = %w[
    TREASURY_PRIVATE_KEY WALLET_MASTER_KEY
    CIRCLE_API_KEY CIRCLE_ENTITY_SECRET CIRCLE_WALLET_SET_ID CIRCLE_WEBHOOK_SECRET
    MONCASH_CLIENT_ID MONCASH_SECRET
    BONID_API_KEY BONID_OAUTH_CLIENT_ID BONID_OAUTH_CLIENT_SECRET
    GRID_CLIENT_ID GRID_CLIENT_SECRET GRID_PLATFORM_ACCOUNT_ID LIGHTSPARK_WEBHOOK_SECRET
    COINMARKETCAP_API_KEY FX_API_KEY
  ].freeze

  # Nothing listens here, so a stray RPC call fails at once instead of
  # reaching Base mainnet.
  UNREACHABLE_RPC = "http://127.0.0.1:9".freeze

  # Before the app class exists: point dotenv at an empty file. An empty list
  # would not work, because Dotenv.load with no files falls back to ".env".
  def self.skip_dotenv!
    Dotenv::Rails.files = [ File::NULL ] if defined?(Dotenv::Rails)
  end

  # First thing in the app class: after dotenv's before_configuration hook,
  # before any initializer. Also clears anything exported in the shell.
  def self.scrub_environment!
    SECRET_VARIABLES.each { |name| ENV.delete(name) }
    ENV["BASE_RPC_URL"] = UNREACHABLE_RPC
  end
end

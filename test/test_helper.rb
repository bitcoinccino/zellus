ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Second layer behind config/test_safety.rb: no test can open a connection to
# anything but this machine, whatever credentials or URLs it ends up with.
module TestNetworkGuard
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1 0.0.0.0].freeze

  class BlockedError < StandardError; end

  def connect
    unless LOCAL_HOSTS.include?(address.to_s)
      raise BlockedError, "Tests may not reach #{address}: outbound network is blocked (see config/test_safety.rb)"
    end

    super
  end
end
Net::HTTP.prepend(TestNetworkGuard)

module ApiTestHelper
  def api_auth_headers(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def setup_transfer_pin!(user, pin)
    user.transfer_pin = pin
    user.save!
  end

  def parsed_response
    JSON.parse(response.body)
  end

  # Assert a JSON hash has exactly the expected keys (no extra, no missing)
  def assert_json_keys(hash, expected_keys, msg = nil)
    actual = hash.keys.sort
    expected = expected_keys.map(&:to_s).sort
    assert_equal expected, actual, msg || "JSON keys mismatch: extra=#{(actual - expected)}, missing=#{(expected - actual)}"
  end

  # Assert a JSON hash has at least the expected keys (extras OK)
  def assert_json_includes_keys(hash, expected_keys, msg = nil)
    missing = expected_keys.map(&:to_s) - hash.keys
    assert_empty missing, msg || "Missing JSON keys: #{missing}"
  end
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

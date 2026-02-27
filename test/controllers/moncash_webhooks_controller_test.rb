require "test_helper"

class MoncashWebhooksControllerTest < ActionDispatch::IntegrationTest
  test "should get create" do
    get moncash_webhooks_create_url
    assert_response :success
  end
end

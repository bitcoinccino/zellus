require "test_helper"

# A user's display_name is already "$cashtag"; the receiver search used to
# print "$tag · $tag". The page now renders through nameWithTag / tagSubline.
class TransferReceiverLabelTest < ActionDispatch::IntegrationTest
  include Warden::Test::Helpers

  setup do
    @user = users(:sender)
    @user.transfer_pin = "4827"
    @user.save!
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  teardown { Warden.test_reset! }

  test "receiver labels go through the de-duplicating helpers" do
    get new_transfer_path
    assert_response :success

    assert_includes response.body, "function nameWithTag(name, cashtag)"
    assert_includes response.body, "nameWithTag(name, cashtag) + ' ' + typeLabel"
    refute_includes response.body, "' + name + ' · $' + cashtag"
    assert_equal 4, response.body.scan("tagSubline(data.display_name, data.cashtag)").size
  end

  test "no currency tip for HTG or USD, and the tip box starts hidden" do
    get new_transfer_path

    refute_includes response.body, "Depans chak jou"
    refute_includes response.body, "Ekonomize a kout tèm"
    refute_includes response.body, "Voye dola dirèkteman nan kont Unibank"
    assert_select "#currency-tip.d-none"
  end
end

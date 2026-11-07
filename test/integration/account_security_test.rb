require "test_helper"
require "minitest/mock"

class AccountSecurityTest < ActionDispatch::IntegrationTest
  include ApiTestHelper
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper
  include Warden::Test::Helpers

  setup do
    @user = users(:sender)
    @wallet = wallets(:sender_wallet)
    @wallet.update!(htg_balance: 100_000, usdc_balance: 1_000)
    @user.transfer_pin = "4827"
    @user.save!
    login_as(@user, scope: :user)
    post login_pin_path, params: { pin: "4827" }
  end

  teardown { Warden.test_reset! }

  # ── 1. Changing the PIN ──

  test "changing the PIN without the current PIN is refused" do
    change_pin(new: "1111")

    assert pin_is?("4827")
    assert_equal "PIN aktyèl la pa kòrèk.", flash[:alert]
  end

  test "a wrong current PIN is refused and counts towards the lockout" do
    change_pin(current: "0000", new: "1111")

    assert pin_is?("4827")
    assert_equal 1, @user.reload.failed_pin_attempts
  end

  test "repeated wrong current PINs lock the account" do
    User::MAX_PIN_ATTEMPTS.times { change_pin(current: "0000", new: "1111") }

    assert @user.reload.pin_locked?
    change_pin(current: "4827", new: "1111")
    assert pin_is?("4827")
    assert_redirected_to login_pin_path
  end

  test "the correct current PIN changes it, alerts the owner and does not hold withdrawals" do
    perform_enqueued_jobs { change_pin(current: "4827", new: "1111") }

    assert pin_is?("1111")
    assert_not @user.reload.outgoing_funds_held?
    assert_security_alert("PIN kont ou a chanje", to: @user.email)
  end

  test "first-time PIN setup does not need a current PIN and sends no alert" do
    @user.update!(transfer_pin: nil)

    assert_no_difference -> { @user.notifications.where(notification_type: "security_alert").count } do
      change_pin(new: "1111")
    end
    assert pin_is?("1111")
  end

  # ── 2. Changing the email ──

  test "the email never changes without the PIN" do
    update_profile({ email: "new@example.org" })

    assert_equal "sender@example.com", @user.reload.email
    assert_redirected_to edit_user_registration_path
    assert_includes flash[:alert], "PIN"
  end

  test "a correct PIN only sends a code, and the email waits for it" do
    update_profile({ email: "new@example.org" }, pin: "4827")

    assert_equal "sender@example.com", @user.reload.email
    assert_redirected_to email_change_path
  end

  test "a wrong code does not change the email" do
    update_profile({ email: "new@example.org" }, pin: "4827")
    post email_change_path, params: { code: "000000" }

    assert_response :unprocessable_entity
    assert_equal "sender@example.com", @user.reload.email
    assert_not @user.outgoing_funds_held?
  end

  test "the right code changes the email, holds withdrawals and alerts the old address" do
    code = request_email_change_code("new@example.org")

    perform_enqueued_jobs { post email_change_path, params: { code: code } }

    assert_equal "new@example.org", @user.reload.email
    assert @user.outgoing_funds_held?
    assert_security_alert("Imèl kont ou a chanje", to: "sender@example.com")
  end

  test "an email already in use is refused" do
    update_profile({ email: users(:receiver).email.upcase }, pin: "4827")

    assert_equal "sender@example.com", @user.reload.email
    assert_equal "Imèl sa a deja itilize.", flash[:alert]
  end

  test "other profile fields save without a PIN when the email is unchanged" do
    update_profile({ email: @user.email, payout_preference: "usd" })

    assert_equal "usd", @user.reload.payout_preference
    assert_not @user.outgoing_funds_held?
  end

  test "the pending-email page needs a pending change" do
    get email_change_path

    assert_redirected_to edit_user_registration_path
  end

  test "the settings page asks for the current PIN and offers a reset" do
    get edit_user_registration_path

    assert_response :success
    assert_select "#pin-update-modal input[name=current_transfer_pin][required]", count: 1
    assert_select "#email-change-pin[hidden] input[name=current_transfer_pin]", count: 1
    assert_select "#pin-update-modal form[action='#{login_pin_reset_path}']", count: 1
  end

  test "the code page shows the new address" do
    update_profile({ email: "new@example.org" }, pin: "4827")
    get email_change_path

    assert_response :success
    assert_select "div", text: "new@example.org"
    assert_select "input[name=code]", count: 1
  end

  # ── 3. and 4. PIN reset ──

  test "a PIN reset holds withdrawals and alerts the owner" do
    post login_pin_reset_path
    code = EmailOtp.generate_for!(@user.email, purpose: "pin_reset")

    perform_enqueued_jobs { post login_pin_reset_verify_path, params: { code: code } }

    assert @user.reload.outgoing_funds_held?
    assert_security_alert("PIN kont ou a reyinisyalize", to: @user.email)
  end

  test "code emails say what the code is for" do
    assert_match "Kòd Konekte", OtpMailer.with(email: "a@example.org", code: "123456").code_email.subject
    assert_match "Reyinisyalize PIN", OtpMailer.with(email: "a@example.org", code: "123456", purpose: "pin_reset").code_email.subject
    assert_match "Chanje Imèl", OtpMailer.with(email: "a@example.org", code: "123456", purpose: "email_change").code_email.subject
  end

  # ── 4. The hold ──

  test "a hold blocks every web withdrawal path without debiting" do
    verify_bonid!
    @user.hold_outgoing_funds!

    {
      withdraw_wallet_path => { amount: 500, moncash_phone: "50912345678", transfer_pin: "4827" },
      withdraw_usd_wallet_path => { amount: 5, wallet_address: "0x#{'a1b2c3d4e5' * 4}", transfer_pin: "4827" },
      withdraw_bank_wallet_path => { amount: 500, bank_account_number: "123", account_holder_name: "Test", transfer_pin: "4827" }
    }.each do |path, params|
      assert_no_difference -> { WalletLedgerEntry.where(wallet: @wallet).count } do
        post path, params: params
      end
      assert_redirected_to wallet_path
      assert_includes flash[:alert], "bloke"
    end
  end

  test "a hold blocks every API withdrawal method without debiting" do
    verify_bonid!
    @user.hold_outgoing_funds!
    token = oauth_tokens(:sender_full_access).access_token

    [
      { amount: 500, asset: "htg", method: "moncash", phone: "50912345678" },
      { amount: 500, asset: "htg", method: "bank", bank_account: "123", account_holder: "Test" },
      { amount: 5, asset: "usd", method: "crypto", wallet_address: "0x#{'a1b2c3d4e5' * 4}" }
    ].each do |params|
      assert_no_difference -> { WalletLedgerEntry.where(wallet: @wallet).count } do
        post api_v1_withdrawals_url, params: params.merge(pin: "4827"), headers: api_auth_headers(token)
      end
      assert_response :forbidden
      assert_includes parsed_response["error"], "bloke"
    end
  end

  test "a hold blocks confirming a web transfer" do
    @user.hold_outgoing_funds!
    transfer = @user.transfers.create!(amount: 100, asset: "htg", receiver_cashtag: "receivergal", note: "x", status: :pending)

    assert_no_debit { post confirm_transfer_path(transfer), params: { transfer_pin: "4827" } }

    assert_redirected_to transfer_path(transfer)
    assert_includes flash[:alert], "bloke"
    assert transfer.reload.pending?
  end

  test "a hold blocks API transfers" do
    @user.hold_outgoing_funds!

    assert_no_difference -> { Transfer.count } do
      assert_no_debit do
        post api_v1_transfers_url,
             params: { amount: 100, asset: "htg", receiver: "receivergal", note: "x", pin: "4827" },
             headers: api_auth_headers(oauth_tokens(:sender_full_access).access_token)
      end
    end
    assert_response :forbidden
    assert_includes parsed_response["error"], "bloke"
  end

  test "a hold blocks paying a payment request" do
    @user.hold_outgoing_funds!
    request = users(:receiver).payment_requests.create!(amount: 100, asset: "htg", note: "x")

    assert_no_debit { post pay_payment_request_path(request.token), params: { transfer_pin: "4827" } }

    assert_includes flash[:alert], "bloke"
    assert_not request.reload.paid?
  end

  test "a hold blocks paying a checkout" do
    @user.hold_outgoing_funds!
    checkout = CheckoutSession.create!(receiver_cashtag: "receivergal", amount: 100, currency: "htg",
                                       success_url: "https://example.org/ok", expires_at: 1.hour.from_now)

    assert_no_debit { post checkout_confirm_path(checkout.token), params: { transfer_pin: "4827" } }

    assert_includes flash[:alert], "bloke"
  end

  test "a hold pauses admin writes but not admin pages" do
    original = ENV["ADMIN_EMAIL"]
    ENV["ADMIN_EMAIL"] = @user.email
    @user.hold_outgoing_funds!

    %w[/admin/credit_wallet /admin/credit_external /admin/reveal_treasury].each do |path|
      post path, params: { transfer_pin: "4827", email: "receivergal", amount: 5 }
      assert_redirected_to admin_root_path
      assert_includes flash[:alert], "bloke"
    end
    assert_nil flash[:treasury_address]

    get admin_root_path
    assert_response :success
  ensure
    ENV["ADMIN_EMAIL"] = original
  end

  test "a hold on the merchant blocks refunding a checkout" do
    @user.hold_outgoing_funds!
    transfer = Transfer.create!(user: users(:receiver), status: :completed, amount: 100, fee: 0, net_amount: 100,
                                asset: :htg, receiver_cashtag: "senderguy", note: "x")
    checkout = CheckoutSession.create!(receiver_cashtag: "senderguy", payer: users(:receiver), transfer: transfer,
                                       amount: 100, currency: "htg", status: :completed,
                                       success_url: "https://example.org/ok", expires_at: 1.hour.from_now)

    assert_no_debit do
      post api_v1_checkout_refund_url(token: checkout.token),
           headers: api_auth_headers(oauth_tokens(:sender_full_access).access_token)
    end
    assert_response :forbidden
    assert_includes parsed_response["error"], "bloke"
  end

  test "a hold blocks selling but not buying" do
    @user.hold_outgoing_funds!

    post transactions_path, params: { transaction_type: "sell", transfer_pin: "4827", crypto_amount_sell: 5 }
    assert_redirected_to new_transaction_path
    assert_includes flash[:alert], "bloke"

    post transactions_path, params: { transaction_type: "buy", transfer_pin: "4827" }
    assert_not_includes flash[:alert].to_s, "bloke"
  end

  test "a hold blocks agent cash-ins" do
    Business.create!(user: @user, name: "Ajan Test", slug: "ajan-test", category: Business::CATEGORIES.keys.first.to_s, status: :active, is_agent: true, agent_status: "approved")
    @user.hold_outgoing_funds!

    post business_agent_transactions_path, params: { amount: 500, customer_identifier: "receivergal", transfer_pin: "4827" }

    assert_redirected_to wallet_path
    assert_includes flash[:alert], "bloke"
  end

  test "a hold leaves conversions within the wallet alone" do
    @user.hold_outgoing_funds!

    post convert_wallet_path, params: { from_asset: "htg", to_asset: "usd", amount: 500, transfer_pin: "4827" }
    assert_not_includes flash[:alert].to_s, "bloke"
  end

  test "out-of-range amounts show the limit instead of crashing" do
    verify_bonid!

    {
      withdraw_wallet_path => { amount: 1, moncash_phone: "50912345678", transfer_pin: "4827" },
      withdraw_bank_wallet_path => { amount: 1, bank_account_number: "123", transfer_pin: "4827" },
      deposit_wallet_path => { amount: 1, transfer_pin: "4827" }
    }.each do |path, params|
      post path, params: params
      assert_redirected_to wallet_path
      assert_includes flash[:alert], "dwe ant"
    end
  end

  test "the hold ends after 24 hours" do
    @user.hold_outgoing_funds!

    travel 23.hours
    assert @user.reload.outgoing_funds_held?

    travel 2.hours
    assert_not @user.reload.outgoing_funds_held?
  end

  private

  def change_pin(new:, current: nil)
    params = { transfer_pin: new, transfer_pin_confirmation: new }
    params[:current_transfer_pin] = current if current
    post set_pin_transfers_path, params: params
  end

  def update_profile(attrs, pin: nil)
    patch user_registration_path, params: { user: attrs, current_transfer_pin: pin }.compact
  end

  def request_email_change_code(email)
    perform_enqueued_jobs { update_profile({ email: email }, pin: "4827") }
    ActionMailer::Base.deliveries.last.subject[/\d{6}/]
  end

  def pin_is?(pin)
    BCrypt::Password.new(@user.reload.transfer_pin_digest) == pin
  end

  def assert_no_debit
    assert_no_difference -> { WalletLedgerEntry.where(wallet: @wallet).count } do
      yield
    end
  end

  def verify_bonid!
    @user.update!(bonid: "BON-SECURITY-TEST", bonid_verified_at: Time.current)
  end

  def assert_security_alert(title, to:)
    assert @user.notifications.exists?(notification_type: "security_alert", title: title)
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ to ], mail.to
    assert_includes mail.subject, title
  end
end

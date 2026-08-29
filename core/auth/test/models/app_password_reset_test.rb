# frozen_string_literal: true

require "test_helper"

# A reset link is a password with an expiry. These are the properties that make
# it safe to email one, each of which could be removed without any request path
# noticing.
class AppPasswordResetTest < ActiveSupport::TestCase
  setup do
    @account = AppUser.create!(domain: "one.test", email: "rider@example.test",
                               password: "original-pass-1")
  end

  test "the token is never stored in readable form" do
    reset, token = AppPasswordReset.start!(app_user: @account)

    assert token.present?
    refute_equal token, reset.token_digest
  end

  test "asking again kills the earlier link" do
    _, first = AppPasswordReset.start!(app_user: @account)
    _, second = AppPasswordReset.start!(app_user: @account)

    assert_equal :used, AppPasswordReset.claim(first).last,
                 "two live keys is one more than somebody asked for"
    assert_equal :ok, AppPasswordReset.claim(second).last
  end

  test "a link works once" do
    reset, token = AppPasswordReset.start!(app_user: @account)

    assert reset.complete!("brand-new-pass-2")
    assert_equal :used, AppPasswordReset.claim(token).last
  end

  test "an expired link says so rather than saying it is not real" do
    reset, token = AppPasswordReset.start!(app_user: @account)
    reset.update!(expires_at: 1.minute.ago)

    assert_equal :expired, AppPasswordReset.claim(token).last,
                 "somebody who read the email late has done nothing wrong and needs to be told what to do"
  end

  test "a token nobody issued is unknown" do
    assert_equal :unknown, AppPasswordReset.claim("not-a-real-token").last
    assert_equal :unknown, AppPasswordReset.claim(nil).last
  end

  test "a link stops working when the account is deactivated" do
    _, token = AppPasswordReset.start!(app_user: @account)
    @account.deactivate!

    assert_equal :unknown, AppPasswordReset.claim(token).last
  end

  test "completing a reset ends every device" do
    _, phone = AppSession.start!(app_user: @account, device_id: "phone")
    _, tablet = AppSession.start!(app_user: @account, device_id: "tablet")
    reset, = AppPasswordReset.start!(app_user: @account)

    reset.complete!("brand-new-pass-2")

    assert_nil AppSession.authenticate(phone)
    assert_nil AppSession.authenticate(tablet),
               "the usual reason to reset a password is that somebody else knows it"
  end

  test "completing a reset changes the password" do
    reset, = AppPasswordReset.start!(app_user: @account)
    reset.complete!("brand-new-pass-2")
    @account.reload

    assert @account.authenticate("brand-new-pass-2")
    refute @account.authenticate("original-pass-1")
  end

  test "a password that fails validation leaves the link usable" do
    reset, token = AppPasswordReset.start!(app_user: @account)

    refute reset.complete!("short")
    assert_equal :ok, AppPasswordReset.claim(token).last,
                 "spending the link on a rejected password would lock somebody out for typing badly"
    assert @account.reload.authenticate("original-pass-1")
  end
end

# frozen_string_literal: true

require "test_helper"

# One account, several devices, each endable on its own. That sentence is the
# whole feature, and these are the ways it could quietly stop being true.
class AppSessionTest < ActiveSupport::TestCase
  setup do
    @account = AppUser.create!(domain: "one.test", email: "rider@example.test",
                               password: "long-enough-1")
  end

  test "the token is never stored in readable form" do
    session, token = AppSession.start!(app_user: @account, device_id: "phone")

    assert token.present?
    refute_equal token, session.token_digest
  end

  test "two devices are two sessions belonging to one account" do
    phone, phone_token = AppSession.start!(app_user: @account, device_id: "phone", device_name: "Pixel")
    tablet, tablet_token = AppSession.start!(app_user: @account, device_id: "tablet", device_name: "iPad")

    refute_equal phone_token, tablet_token
    assert_equal @account, AppSession.authenticate(phone_token).app_user
    assert_equal @account, AppSession.authenticate(tablet_token).app_user
    assert_equal 2, @account.app_sessions.active.count
    refute_equal phone.id, tablet.id
  end

  test "ending one device leaves the others signed in" do
    _, phone_token = AppSession.start!(app_user: @account, device_id: "phone")
    tablet, tablet_token = AppSession.start!(app_user: @account, device_id: "tablet")

    tablet.revoke!

    assert_nil AppSession.authenticate(tablet_token)
    assert AppSession.authenticate(phone_token),
           "losing a phone must not sign somebody out of everything else they own"
  end

  test "signing in again from the same device replaces that device" do
    _, first = AppSession.start!(app_user: @account, device_id: "phone")
    _, second = AppSession.start!(app_user: @account, device_id: "phone")

    assert_nil AppSession.authenticate(first),
               "a reinstall would otherwise leave a row nobody can tell apart"
    assert AppSession.authenticate(second)
    assert_equal 1, @account.app_sessions.active.count
  end

  test "a device with no id is left alone by another sign-in" do
    _, first = AppSession.start!(app_user: @account)
    _, second = AppSession.start!(app_user: @account)

    assert AppSession.authenticate(first),
           "with nothing to match on, replacing would end a session belonging to another device"
    assert AppSession.authenticate(second)
  end

  test "an expired session stops authenticating" do
    session, token = AppSession.start!(app_user: @account, device_id: "phone")
    session.update!(expires_at: 1.minute.ago)

    assert_nil AppSession.authenticate(token)
  end

  test "the device summary carries nothing secret" do
    session, = AppSession.start!(app_user: @account, device_id: "phone", device_name: "Pixel",
                                 platform: "android", ip_address: "10.0.0.9")
    summary = session.to_device

    refute summary.key?(:token_digest)
    refute summary.key?(:ip_address)
    assert_equal "Pixel", summary[:name]
  end

  test "a device with no name is still nameable in a list" do
    session, = AppSession.start!(app_user: @account, platform: "ios")

    assert_equal "ios", session.to_device[:name]
  end
end

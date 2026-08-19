# frozen_string_literal: true

require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "a@example.test", password: "password123", name: "A")
  end

  test "starting a session returns a token that is never stored in readable form" do
    session, token = Session.start!(user: @user, domain: "example.test")

    assert token.present?
    refute_equal token, session.token_digest
  end

  test "the token authenticates the session it belongs to" do
    session, token = Session.start!(user: @user, domain: "example.test")

    assert_equal session, Session.authenticate(token)
  end

  test "a revoked session stops authenticating immediately" do
    session, token = Session.start!(user: @user, domain: "example.test")
    session.revoke!

    assert_nil Session.authenticate(token),
               "a session that cannot be revoked is a bearer grant, not a session"
  end

  test "an expired session stops authenticating" do
    session, token = Session.start!(user: @user, domain: "example.test")
    session.update!(expires_at: 1.minute.ago)

    assert_nil Session.authenticate(token)
  end

  test "a blank or unknown token authenticates nobody" do
    Session.start!(user: @user, domain: "example.test")

    assert_nil Session.authenticate("")
    assert_nil Session.authenticate(nil)
    assert_nil Session.authenticate("not-a-real-token")
  end

  test "destroying a user takes their sessions with them" do
    Session.start!(user: @user, domain: "example.test")

    assert_difference("Session.count", -1) { @user.destroy }
  end
end

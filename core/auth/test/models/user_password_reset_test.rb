# frozen_string_literal: true

require "test_helper"

# The core account half of the reset rules. `ResetToken` is one implementation
# over two tables, so these are mostly about it being wired to the right one:
# a core reset must end core sessions, and the two kinds must not reach each
# other.
class UserPasswordResetTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "operator@example.test", password: "original-pass-1")
  end

  test "a link works once and then says it was used" do
    reset, token = UserPasswordReset.start!(@user)

    assert reset.complete!("brand-new-pass-2")
    assert_equal :used, UserPasswordReset.claim(token).last
    assert @user.reload.authenticate("brand-new-pass-2")
  end

  test "asking again kills the earlier link" do
    _, first = UserPasswordReset.start!(@user)
    _, second = UserPasswordReset.start!(@user)

    assert_equal :used, UserPasswordReset.claim(first).last
    assert_equal :ok, UserPasswordReset.claim(second).last
  end

  test "an expired link says so rather than saying it is not real" do
    reset, token = UserPasswordReset.start!(@user)
    reset.update!(expires_at: 1.minute.ago)

    assert_equal :expired, UserPasswordReset.claim(token).last
  end

  test "a rejected password does not spend the link" do
    reset, token = UserPasswordReset.start!(@user)

    refute reset.complete!("short")
    assert_equal :ok, UserPasswordReset.claim(token).last
    assert @user.reload.authenticate("original-pass-1")
  end

  test "completing a reset ends every core session" do
    _, one = Session.start!(user: @user, domain: "example.test")
    _, two = Session.start!(user: @user, domain: "other.test")
    reset, = UserPasswordReset.start!(@user)

    reset.complete!("brand-new-pass-2")

    assert_nil Session.authenticate(one)
    assert_nil Session.authenticate(two)
  end

  test "a link stops working when the account is deactivated" do
    _, token = UserPasswordReset.start!(@user)
    @user.deactivate!

    assert_equal :unknown, UserPasswordReset.claim(token).last
  end

  # The two tables are separate on purpose. A token minted for one kind of
  # account must be meaningless to the other.
  test "an app account's token is not a core account's token" do
    app_account = AppUser.create!(domain: "one.test", email: "rider@example.test",
                                  password: "long-enough-1")
    _, app_token = AppPasswordReset.start!(app_account)

    assert_equal :unknown, UserPasswordReset.claim(app_token).last
  end

  test "and the reverse" do
    _, core_token = UserPasswordReset.start!(@user)

    assert_equal :unknown, AppPasswordReset.claim(core_token).last
  end
end

# frozen_string_literal: true

require "test_helper"

# The rules that make an app account a different thing from a core account.
# Each of these is a property somebody could remove without any other test
# noticing, and each of them is the reason the second table exists.
class AppUserTest < ActiveSupport::TestCase
  setup do
    @account = AppUser.create!(domain: "one.test", email: "rider@example.test",
                               password: "long-enough-1", name: "Rider")
  end

  test "the same email on two domains is two people" do
    other = AppUser.new(domain: "two.test", email: "rider@example.test", password: "long-enough-1")

    assert other.save, "an app account belongs to one domain, so the address is free on another"
    refute_equal @account.id, other.id
  end

  test "the same email twice on one domain is refused" do
    duplicate = AppUser.new(domain: "one.test", email: "rider@example.test", password: "long-enough-1")

    refute duplicate.valid?
    assert_includes duplicate.errors.full_messages.join, "Email"
  end

  test "case and surrounding space do not create a second account" do
    duplicate = AppUser.new(domain: "one.test", email: "  Rider@Example.test ", password: "long-enough-1")

    refute duplicate.valid?,
           "an address that only differs in case is the same address, and the index agrees"
  end

  test "an app account is never an operator" do
    identity = @account.to_identity

    refute identity[:operator]
    assert identity[:app_user]
    refute @account.permission_set.allow?("core.users.read")
    refute @account.permission_set.allow?("core.modules.read")
  end

  test "an app account may use the product and every module in it" do
    assert @account.permission_set.allow?("app.use")
    assert @account.permission_set.allow?("module.demo-tasks.use")
  end

  test "deactivating ends every device, not the one that asked" do
    _, first = AppSession.start!(app_user: @account, device_id: "a")
    _, second = AppSession.start!(app_user: @account, device_id: "b")

    @account.deactivate!

    assert_nil AppSession.authenticate(first)
    assert_nil AppSession.authenticate(second),
               "an inactive account with a live session on a phone is an active account"
  end


  test "a new account has not verified its address" do
    refute @account.verified?
    refute @account.to_identity[:verified]
  end

  test "following the link verifies it, once" do
    token = @account.start_verification!

    assert_equal @account, AppUser.verify!(token)
    assert @account.reload.verified?
    assert_nil AppUser.verify!(token),
               "a link that keeps working is a second credential sitting in a mailbox"
  end

  test "a token nobody issued verifies nobody" do
    @account.start_verification!

    assert_nil AppUser.verify!("not-a-real-token")
    assert_nil AppUser.verify!(nil)
    refute @account.reload.verified?
  end

  test "asking again replaces the link rather than adding one" do
    first = @account.start_verification!
    second = @account.start_verification!

    assert_nil AppUser.verify!(first)
    assert_equal @account, AppUser.verify!(second)
  end

  # Recorded, never enforced. A broken mail transport must not be able to lock
  # every new account out of a product that was working.
  test "an unverified account can still sign in" do
    _, token = AppSession.start!(app_user: @account, device_id: "phone")

    refute @account.verified?
    assert AppSession.authenticate(token)
  end

  # Ending an account, which the person whose account it is can now do.
  test "erasing ends every session" do
    _, phone = AppSession.start!(app_user: @account, device_id: "phone")
    _, tablet = AppSession.start!(app_user: @account, device_id: "tablet")

    @account.erase!

    assert_nil AppSession.authenticate(phone)
    assert_nil AppSession.authenticate(tablet)
  end

  test "erasing leaves nothing to sign in with" do
    @account.erase!

    refute @account.reload.authenticate("long-enough-1")
    refute @account.active
    assert @account.deleted?
  end

  # The property this whole shape exists for. Every module keys its rows by
  # email, so freeing the address would hand the next person to claim it the
  # previous one's tasks and notes.
  test "the address stays claimed, so it cannot be handed to somebody else" do
    @account.erase!

    successor = AppUser.new(domain: "one.test", email: "rider@example.test",
                            password: "somebody-else-2")

    refute successor.valid?,
           "an address that has been used cannot be recycled while modules key by it"
  end

  test "an erased account is not active anywhere that matters" do
    @account.erase!

    assert_nil AppUser.on("one.test").active.find_by(email: "rider@example.test")
  end

  test "a live reset link does not survive the account" do
    _, token = AppPasswordReset.start!(@account)

    @account.erase!

    assert_equal :unknown, AppPasswordReset.claim(token).last,
                 "a link in a mailbox must not outlive the account it opens"
  end

  test "erasing forgets the name and the verification" do
    @account.update!(name: "Rider", verified_at: Time.current)

    @account.erase!

    assert_nil @account.reload.name
    refute @account.verified?
  end
  test "the identity carries the domain, because the same address exists elsewhere" do
    assert_equal "one.test", @account.to_identity[:domain]
  end
end

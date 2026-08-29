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

  test "the identity carries the domain, because the same address exists elsewhere" do
    assert_equal "one.test", @account.to_identity[:domain]
  end
end

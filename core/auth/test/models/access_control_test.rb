# frozen_string_literal: true

require "test_helper"

class AccessControlTest < ActiveSupport::TestCase
  setup do
    Role.seed_defaults!
    @user = User.create!(email: "alex@example.test", password: "password123", name: "Alex")
  end

  def role(name) = Role.find_by(name: name)

  # Resolution -----------------------------------------------------------

  test "somebody with no roles can do nothing at all" do
    assert @user.resolved_permissions.empty?
    refute @user.resolved_permissions.allow?("app.use")
  end

  test "a role grants everything it lists" do
    @user.role_assignments.create!(role: role("member"))

    permissions = @user.reload.resolved_permissions
    assert permissions.allow?("app.use")
    assert permissions.allow?("module.demo-tasks.use")
    refute permissions.allow?("core.modules.read")
  end

  test "two roles union" do
    @user.role_assignments.create!(role: role("member"))
    @user.role_assignments.create!(role: role("operator"))

    permissions = @user.reload.resolved_permissions
    assert permissions.allow?("app.use"), "from member"
    assert permissions.allow?("core.modules.install"), "from operator"
  end

  test "a direct grant adds one thing without inventing a role for it" do
    @user.role_assignments.create!(role: role("member"))
    @user.permission_grants.create!(permission: "core.audit.read", effect: "allow")

    assert @user.reload.resolved_permissions.allow?("core.audit.read")
  end

  test "a deny beats a role that grants it" do
    @user.role_assignments.create!(role: role("owner"))
    @user.permission_grants.create!(permission: "core.modules.remove", effect: "deny",
                                     reason: "an operator, except for this")

    permissions = @user.reload.resolved_permissions
    assert permissions.allow?("core.modules.install"), "owner still grants the rest"
    refute permissions.allow?("core.modules.remove")
  end

  test "operator is derived from permissions rather than set by hand" do
    refute @user.operator?

    @user.role_assignments.create!(role: role("operator"))
    assert @user.reload.operator?
  end

  test "the identity handed to other services carries no secrets" do
    @user.role_assignments.create!(role: role("member"))

    identity = @user.reload.to_identity

    refute identity.key?(:password_digest)
    refute identity.values.map(&:to_s).any? { |value| value.include?("$2a$") }
    assert_includes identity[:permissions], "app.use"
  end

  # Versioning -----------------------------------------------------------

  test "assigning a role bumps the version" do
    before = @user.permissions_version

    @user.role_assignments.create!(role: role("member"))

    assert_operator @user.reload.permissions_version, :>, before
  end

  test "editing a role bumps the version of everybody holding it" do
    @user.role_assignments.create!(role: role("member"))
    before = @user.reload.permissions_version

    role("member").update!(permissions: %w[app.use])

    assert_operator @user.reload.permissions_version, :>, before,
                    "changing what a role grants has to invalidate its holders"
  end

  test "a grant bumps the version" do
    before = @user.permissions_version

    @user.permission_grants.create!(permission: "core.audit.read", effect: "allow")

    assert_operator @user.reload.permissions_version, :>, before
  end

  # Sessions carry the resolved answer -----------------------------------

  test "a session carries the set as it stood when it started" do
    @user.role_assignments.create!(role: role("member"))
    session, = Session.start!(user: @user.reload, domain: "example.test")

    assert session.permission_set.allow?("app.use")
    assert_equal @user.reload.permissions_version, session.permissions_version
  end

  test "a session with a stale version re-resolves rather than answering wrongly" do
    @user.role_assignments.create!(role: role("member"))
    session, = Session.start!(user: @user.reload, domain: "example.test")
    assert session.permission_set.allow?("module.demo-tasks.use")

    @user.permission_grants.create!(permission: "module.demo-tasks.use", effect: "deny")

    assert session.reload.stale?, "the version stamp is what makes staleness detectable"
    refute session.permission_set.allow?("module.demo-tasks.use"),
           "a stale session must re-resolve, not serve the answer it cached"
  end

  test "a session that is not stale does not re-resolve" do
    @user.role_assignments.create!(role: role("member"))
    session, = Session.start!(user: @user.reload, domain: "example.test")

    refute session.stale?
    assert_no_changes -> { session.reload.updated_at } do
      session.permission_set
    end
  end

  # Deactivation ---------------------------------------------------------

  test "deactivating somebody ends their sessions" do
    @user.role_assignments.create!(role: role("member"))
    _session, token = Session.start!(user: @user.reload, domain: "example.test")

    @user.deactivate!

    assert_nil Session.authenticate(token),
               "an inactive account with a live session is an active account"
  end

  test "a session belonging to a deactivated account stops authenticating" do
    _session, token = Session.start!(user: @user, domain: "example.test")
    @user.update_columns(active: false)

    assert_nil Session.authenticate(token)
  end

  # Roles ----------------------------------------------------------------

  test "seeding twice does not duplicate or overwrite" do
    role("member").update!(description: "edited by hand")

    Role.seed_defaults!

    assert_equal 3, Role.count
    assert_equal "edited by hand", role("member").description,
                 "seeded roles are ordinary roles, and an edit should survive a reseed"
  end

  test "a role rejects permissions that are not strings" do
    bad = Role.new(name: "broken", permissions: [{ permission: "core.users.read" }])

    refute bad.valid?
  end
end

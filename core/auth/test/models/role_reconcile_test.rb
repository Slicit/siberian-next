# frozen_string_literal: true

require "test_helper"

# Delivering a permission that was added to the catalogue after an installation
# was already seeded.
#
# The interesting cases are all about telling two things apart that look
# identical in the role's own permission list: a permission that was never
# offered, and one that was offered and removed on purpose.
class RoleReconcileTest < ActiveSupport::TestCase
  setup { Role.seed_defaults! }

  def role(name) = Role.find_by(name: name)

  def with_catalogue(name, permissions)
    original = Siberian::Permissions::SEEDED_ROLES
    replacement = original.merge(name => original.fetch(name).merge(permissions: permissions))
    Siberian::Permissions.send(:remove_const, :SEEDED_ROLES)
    Siberian::Permissions.const_set(:SEEDED_ROLES, replacement.freeze)
    yield
  ensure
    Siberian::Permissions.send(:remove_const, :SEEDED_ROLES)
    Siberian::Permissions.const_set(:SEEDED_ROLES, original)
  end

  test "seeding records what the catalogue granted" do
    assert_equal role("member").permission_list.sort, role("member").seeded_permission_list.sort
  end

  test "a permission added to the catalogue reaches an already seeded role" do
    refute role("member").grants?("app.reports")

    added = with_catalogue("member", %w[app.use module.*.use app.reports]) do
      Role.reconcile_seeded!
    end

    assert_equal({ "member" => ["app.reports"] }, added)
    assert role("member").reload.grants?("app.reports")
  end

  test "reconciling twice adds nothing the second time" do
    with_catalogue("member", %w[app.use module.*.use app.reports]) do
      Role.reconcile_seeded!
      assert_empty Role.reconcile_seeded!
    end
  end

  test "a permission the operator removed does not come back" do
    with_catalogue("member", %w[app.use module.*.use app.reports]) do
      Role.reconcile_seeded!
    end

    role("member").update!(permissions: %w[app.use module.*.use])

    with_catalogue("member", %w[app.use module.*.use app.reports]) do
      assert_empty Role.reconcile_seeded!
    end
    refute role("member").reload.grants?("app.reports")
  end

  test "an operator's own additions survive reconciling" do
    role("member").update!(permissions: role("member").permission_list + ["core.audit.read"])

    with_catalogue("member", %w[app.use module.*.use app.reports]) do
      Role.reconcile_seeded!
    end

    assert role("member").reload.grants?("core.audit.read")
    assert role("member").grants?("app.reports")
  end

  test "a role that already covers a new permission by wildcard is left alone" do
    before = role("owner").permission_list

    with_catalogue("owner", ["*", "app.reports"]) do
      assert_empty Role.reconcile_seeded!
    end

    assert_equal before, role("owner").reload.permission_list
  end

  test "a role an operator created is never touched" do
    mine = Role.create!(name: "reviewer", permissions: %w[app.use])

    with_catalogue("member", %w[app.use module.*.use app.reports]) do
      Role.reconcile_seeded!
    end

    assert_equal %w[app.use], mine.reload.permission_list
  end

  test "everybody holding a changed role has to resolve again" do
    user = User.create!(email: "sam@example.test", password: "password123", name: "Sam")
    user.role_assignments.create!(role: role("member"))
    before = user.reload.permissions_version

    with_catalogue("member", %w[app.use module.*.use app.reports]) do
      Role.reconcile_seeded!
    end

    assert_operator user.reload.permissions_version, :>, before,
                    "a role gaining a permission has to invalidate its holders"
  end
end

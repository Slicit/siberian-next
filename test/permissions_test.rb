# frozen_string_literal: true

require_relative "test_helper"
require "lib/permissions"

class PermissionsTest < Minitest::Test
  include Siberian

  Set = Permissions::Set

  # Matching ---------------------------------------------------------------

  def test_an_exact_grant_matches_itself_and_nothing_else
    assert Permissions.match?("core.users.read", "core.users.read")
    refute Permissions.match?("core.users.read", "core.users.write")
    refute Permissions.match?("core.users.read", "core.users")
  end

  def test_a_trailing_wildcard_takes_the_rest
    assert Permissions.match?("core.users.*", "core.users.read")
    assert Permissions.match?("core.*", "core.users.read"), "a group grant has to reach deeper than one level"
    assert Permissions.match?("*", "anything.at.all")
  end

  def test_a_trailing_wildcard_needs_something_to_match
    refute Permissions.match?("core.users.*", "core.users"),
           "a wildcard is not an empty string, or granting core.* would grant core itself"
  end

  def test_an_interior_wildcard_is_exactly_one_segment
    assert Permissions.match?("module.*.use", "module.demo-tasks.use")
    refute Permissions.match?("module.*.use", "module.a.b.use"),
           "one segment means one, or module.*.use would reach into nested namespaces"
    refute Permissions.match?("module.*.use", "module.use")
  end

  def test_a_pattern_longer_than_the_permission_matches_nothing
    refute Permissions.match?("core.users.read.extra", "core.users.read")
  end

  def test_empty_input_matches_nothing
    refute Permissions.match?("", "core.users.read")
    refute Permissions.match?("core.users.read", "")
  end

  # Sets -------------------------------------------------------------------

  def test_a_set_answers_from_exact_grants
    set = Set.new(%w[core.users.read app.use])

    assert set.allow?("core.users.read")
    refute set.allow?("core.users.write")
  end

  def test_a_set_answers_from_wildcard_grants
    set = Set.new(%w[core.modules.* module.*.use])

    assert set.allow?("core.modules.install")
    assert set.allow?("module.demo-tasks.use")
    refute set.allow?("module.demo-tasks.admin")
  end

  def test_deny_beats_any_grant
    set = Set.new(%w[*], denied: %w[core.modules.remove])

    assert set.allow?("core.modules.install"), "the star still grants everything else"
    refute set.allow?("core.modules.remove"), "an explicit deny cannot be overridden, that is the point of it"
  end

  def test_deny_can_itself_be_a_pattern
    set = Set.new(%w[*], denied: %w[core.users.*])

    refute set.allow?("core.users.read")
    refute set.allow?("core.users.write")
    assert set.allow?("core.modules.install")
  end

  def test_nobody_allows_nothing
    assert Permissions::Set.none.deny?("app.use")
    assert Permissions::Set.none.empty?
  end

  def test_any_and_all_read_the_way_they_are_written
    set = Set.new(%w[core.users.read app.use])

    assert set.any?("core.users.write", "core.users.read")
    refute set.any?("core.users.write", "core.roles.manage")
    assert set.all?("core.users.read", "app.use")
    refute set.all?("core.users.read", "core.users.write")
  end

  def test_a_set_survives_a_round_trip_through_json
    original = Set.new(%w[core.* app.use], denied: %w[core.users.write])

    restored = Set.from_json(JSON.parse(original.to_json))

    assert restored.allow?("core.modules.install")
    refute restored.allow?("core.users.write")
    assert_equal original.to_a.sort, restored.to_a.sort
  end

  # The seeded roles have to mean what they say --------------------------

  def test_the_owner_role_can_do_everything
    set = Set.new(Permissions::SEEDED_ROLES.fetch("owner")[:permissions])

    Permissions::CATALOGUE.each do |entry|
      assert set.allow?(entry[:permission].sub("*", "example")),
             "owner should cover #{entry[:permission]}"
    end
  end

  def test_the_operator_role_runs_the_system_but_cannot_rewrite_access
    set = Set.new(Permissions::SEEDED_ROLES.fetch("operator")[:permissions])

    assert set.allow?("core.modules.install")
    assert set.allow?("core.domains.manage")
    assert set.allow?("core.users.read")
    refute set.allow?("core.users.write"), "running the system is not the same as deciding who runs it"
    refute set.allow?("core.roles.manage")
  end

  def test_the_member_role_uses_the_product_and_nothing_else
    set = Set.new(Permissions::SEEDED_ROLES.fetch("member")[:permissions])

    assert set.allow?("app.use")
    assert set.allow?("module.demo-tasks.use")
    refute set.allow?("core.modules.read")
    refute set.allow?("core.users.read")
  end

  def test_every_catalogue_entry_is_unique_and_grouped
    permissions = Permissions::CATALOGUE.map { |entry| entry[:permission] }

    assert_equal permissions.uniq, permissions
    assert Permissions::CATALOGUE.all? { |entry| entry[:group].to_s != "" }
    assert Permissions::CATALOGUE.all? { |entry| entry[:label].to_s != "" }
  end
end

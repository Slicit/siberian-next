# frozen_string_literal: true

require_relative "test_helper"
require "lib/contracts"

class NavigationTest < Minitest::Test
  include Siberian

  CONTROLLERS = File.expand_path("../core/orchestrator/app/controllers", __dir__)

  def allow_only(*permissions)
    set = Permissions::Set.new(permissions)
    ->(permission) { set.allow?(permission) }
  end

  def labels_for(*permissions)
    Navigation.visible(allow: allow_only(*permissions)).flat_map { |group| group.entries.map(&:label) }
  end

  # The bug this whole file exists for. A link that asks for more than its page
  # does hides a page somebody is allowed to open, and nothing anywhere reports
  # it: the menu simply has one fewer entry than it should.
  def test_every_entry_asks_for_exactly_what_its_page_requires
    Navigation.entries.each do |entry|
      next if entry[:permission].nil?

      path = File.join(CONTROLLERS, "#{entry[:controller]}_controller.rb")
      next unless File.exist?(path)

      # The class-level requires, without an `only:`, is what the page asks of
      # everybody who opens it. A requires with `only:` guards one action and
      # must never decide whether the link is shown.
      required = File.read(path)[/^\s*requires "([^"]+)"\s*$/, 1]

      assert_equal required, entry[:permission],
                   "the #{entry[:label]} link asks for #{entry[:permission]}, but #{entry[:controller]} requires #{required}"
    end
  end

  def test_the_owner_sees_everything
    labels = labels_for("*")

    assert_equal Navigation.entries.map { |entry| entry[:label] }, labels
  end

  def test_the_seeded_operator_keeps_every_entry_that_role_can_open
    labels = labels_for(*Permissions::SEEDED_ROLES["operator"][:permissions])

    assert_includes labels, "Catalogue"
    assert_includes labels, "Storage"
    assert_includes labels, "Phone apps"
    assert_includes labels, "Activity"
    refute_includes labels, "Roles", "an operator cannot manage roles, so the link would lead to a refusal"
  end

  # Somebody granted one thing should see one thing, not a heading with nothing
  # under it.
  def test_a_group_with_nothing_visible_in_it_is_dropped
    groups = Navigation.visible(allow: allow_only("core.users.read"))

    assert_equal ["Operate", "Access"], groups.map(&:label)
    assert_equal ["Overview"], groups.first.entries.map(&:label)
    assert_equal ["People"], groups.last.entries.map(&:label)
  end

  def test_overview_is_visible_to_anybody_who_reaches_the_backoffice_at_all
    assert_equal ["Overview"], labels_for
  end

  def test_a_wildcard_grant_opens_the_group_it_covers
    labels = labels_for("core.modules.*")

    assert_includes labels, "Modules"
    assert_includes labels, "Catalogue"
    refute_includes labels, "People"
  end
end

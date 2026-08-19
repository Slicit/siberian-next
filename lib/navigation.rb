# frozen_string_literal: true

module Siberian
  # The Backoffice's left hand menu, as data.
  #
  # It was a run of conditionals in the layout, and the trouble with that is
  # that the condition on a link and the permission on the page it leads to are
  # written in two files by two different people on two different days. They
  # drifted: the Catalogue link asked for `core.modules.install` while the
  # Catalogue page asks only for `core.modules.read`, so somebody allowed to
  # look at the catalogue had no way to reach it.
  #
  # As data it can be checked against the controllers themselves, which is what
  # `test/navigation_test.rb` does.
  module Navigation
    Entry = Struct.new(:label, :route, :permission, :controller, keyword_init: true)
    Group = Struct.new(:label, :entries, keyword_init: true)

    # `permission` is what the page itself requires of everybody, not what the
    # most privileged action on it requires. A link that asks for more than the
    # page does hides a page somebody is allowed to open.
    BACKOFFICE = [
      {
        label: "Operate",
        entries: [
          { label: "Overview", route: :root_path, permission: nil, controller: "dashboard" },
          { label: "Modules", route: :modules_path, permission: "core.modules.read", controller: "modules" },
          { label: "Catalogue", route: :catalog_path, permission: "core.modules.read", controller: "catalog" }
        ]
      },
      {
        label: "Access",
        entries: [
          { label: "People", route: :people_path, permission: "core.users.read", controller: "people" },
          { label: "Roles", route: :roles_path, permission: "core.roles.manage", controller: "roles" }
        ]
      },
      {
        label: "System",
        entries: [
          { label: "Domains", route: :domains_path, permission: "core.domains.manage", controller: "domains" },
          { label: "Storage", route: :storage_path, permission: "core.modules.read", controller: "storage" },
          { label: "Phone apps", route: :mobile_path, permission: "core.modules.read", controller: "mobile" },
          { label: "Interfaces", route: :interfaces_path, permission: "core.modules.read", controller: "interfaces" },
          { label: "Activity", route: :activity_path, permission: "core.audit.read", controller: "activities" }
        ]
      }
    ].freeze

    # The groups somebody can actually see.
    #
    # A group whose entries are all hidden is dropped rather than rendered as a
    # heading with nothing under it, which reads as a menu that lost something.
    def self.visible(allow:)
      BACKOFFICE.filter_map do |group|
        entries = group[:entries].filter_map do |entry|
          next unless entry[:permission].nil? || allow.call(entry[:permission])

          Entry.new(**entry)
        end

        next if entries.empty?

        Group.new(label: group[:label], entries: entries)
      end
    end

    def self.entries = BACKOFFICE.flat_map { |group| group[:entries] }
  end
end

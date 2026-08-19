# frozen_string_literal: true

require "set"
require "json"

module Siberian
  # Permissions, and the rules for matching them.
  #
  # Shared rather than reimplemented per service, because two services that
  # disagree about whether somebody may do a thing is the worst outcome
  # available: one of them is wrong and neither knows which.
  module Permissions
    SEPARATOR = "."
    WILDCARD = "*"

    # The vocabulary the core ships with. Modules extend it at install time with
    # `module.<name>.*`, which is the reason permissions are strings and not
    # columns: the set of verbs is not knowable when the schema is written.
    #
    # Ordered, because this is also what the permission editor renders.
    CATALOGUE = [
      { group: "People", permission: "core.users.read", label: "See people and their access" },
      { group: "People", permission: "core.users.write", label: "Add, edit, and deactivate people" },
      { group: "People", permission: "core.roles.manage", label: "Create roles and change what they grant",
        note: "Includes granting permissions this account does not itself hold." },

      { group: "Modules", permission: "core.modules.read", label: "See installed modules and their state" },
      { group: "Modules", permission: "core.modules.install", label: "Install a module",
        note: "Installing approves everything the module asked for." },
      { group: "Modules", permission: "core.modules.remove", label: "Remove a module" },

      { group: "System", permission: "core.domains.manage", label: "Add and remove domains" },
      { group: "System", permission: "core.storage.manage", label: "Set storage quotas",
        note: "Raising a quota spends a disk everybody shares." },
      { group: "System", permission: "core.audit.read", label: "Read the audit trail" },
      { group: "System", permission: "core.settings.write", label: "Change product settings" },

      { group: "Product", permission: "app.use", label: "Sign in to the product" },
      { group: "Product", permission: "module.*.use", label: "Open every installed module",
        note: "Grant `module.<name>.use` instead to allow one." }
    ].freeze

    # Roles the system seeds. Not fixed: an operator can edit or delete any of
    # them. They exist so a fresh installation is usable rather than locked.
    SEEDED_ROLES = {
      "owner" => {
        description: "Everything, including changing who else can do what.",
        permissions: ["*"]
      },
      "operator" => {
        description: "Runs the system: modules, domains, and the audit trail.",
        permissions: %w[core.modules.* core.domains.manage core.storage.manage core.audit.read core.users.read app.use module.*.use]
      },
      "member" => {
        description: "Uses the product and every module in it.",
        permissions: %w[app.use module.*.use]
      }
    }.freeze

    # Does `pattern` cover `permission`?
    #
    #   core.users.*   covers core.users.read        the last segment takes the rest
    #   core.*         covers core.users.read        so a group grant works
    #   module.*.use   covers module.tasks.use       a middle wildcard is exactly one segment
    #   module.*.use   does NOT cover module.a.b.use because that is two
    #   *              covers everything
    #
    # The distinction between a trailing and an interior wildcard is the only
    # rule here worth memorising, and it exists because both readings are wanted:
    # "everything under core" and "any module, but only the use verb".
    def self.match?(pattern, permission)
      return false if pattern.to_s.empty? || permission.to_s.empty?
      return true if pattern == WILDCARD

      pattern_parts = pattern.to_s.split(SEPARATOR)
      permission_parts = permission.to_s.split(SEPARATOR)

      pattern_parts.each_with_index do |part, index|
        last = index == pattern_parts.length - 1

        if part == WILDCARD && last
          # Takes the rest, and there has to be a rest to take.
          return permission_parts.length > index
        end

        return false if index >= permission_parts.length
        next if part == WILDCARD
        return false unless part == permission_parts[index]
      end

      pattern_parts.length == permission_parts.length
    end

    # A resolved answer for one person, at one moment.
    #
    # Built once per session and then asked many times, which is the whole
    # performance argument: a sidebar with twelve capabilities asks twelve
    # questions before it renders, and every one of them is a set lookup here
    # rather than a query or a network call.
    class Set
      attr_reader :granted, :denied

      def initialize(granted = [], denied: [])
        @granted = Array(granted).map(&:to_s).uniq.freeze
        @denied = Array(denied).map(&:to_s).uniq.freeze
        # Exact grants are the common case, so they skip pattern matching.
        @exact = @granted.reject { |pattern| pattern.include?(WILDCARD) }.to_set
        @patterns = @granted.select { |pattern| pattern.include?(WILDCARD) }.freeze
      end

      # Deny is checked first and cannot be overridden. The useful real shape is
      # "an operator, except for this one thing", and expressing that by
      # carefully not granting something is fragile: the next role that grants
      # it silently undoes the intent.
      def allow?(permission)
        permission = permission.to_s
        return false if denied_by_any?(permission)
        return true if @exact.include?(permission)

        @patterns.any? { |pattern| Permissions.match?(pattern, permission) }
      end

      def deny?(permission) = !allow?(permission)

      def any?(*permissions)
        permissions.flatten.any? { |permission| allow?(permission) }
      end

      def all?(*permissions)
        permissions.flatten.all? { |permission| allow?(permission) }
      end

      def empty? = @granted.empty?

      def to_a = @granted
      def to_json(*args) = { granted: @granted, denied: @denied }.to_json(*args)

      def self.from_json(payload)
        payload ||= {}
        payload = JSON.parse(payload) if payload.is_a?(String)
        new(payload["granted"] || payload[:granted] || [],
            denied: payload["denied"] || payload[:denied] || [])
      end

      # Nobody, for a request with no session. Deliberately a real object rather
      # than nil, so callers ask the same question either way.
      def self.none = new([])

      private

      def denied_by_any?(permission)
        @denied.any? { |pattern| Permissions.match?(pattern, permission) }
      end
    end
  end
end

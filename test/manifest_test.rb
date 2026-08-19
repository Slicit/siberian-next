# frozen_string_literal: true

require_relative "test_helper"
require "lib/contracts"

class ManifestTest < Minitest::Test
  include Siberian

  UUID = "0191d3f2"

  def manifest(overrides = "")
    Contracts::Manifest.parse(<<~YAML + overrides)
      schema_version: 1
      name: example-notes
      version: 1.0.0
      title: Example Notes
      containers:
        - service: web
          image: nginx:1.27-alpine
          role: http
          internal_port: 80
          health:
            path: /up
            interval_seconds: 15
        - service: cache
          image: redis:7-alpine
          role: datastore
      routes:
        base: /example-notes
        entry: web
    YAML
  end

  def reference_manifest
    Contracts::Manifest.load(File.expand_path("../modules/example-notes/module.yml", __dir__))
  end

  # Naming ---------------------------------------------------------------

  def test_container_names_follow_the_uuid_module_service_rule
    specs = manifest.container_specs(uuid: UUID)

    assert_equal ["#{UUID}-example-notes-web", "#{UUID}-example-notes-cache"], specs.map(&:name)
  end

  def test_the_network_is_named_for_the_installation_not_the_module
    assert_equal "siberian-mod-#{UUID}", manifest.network_name(UUID)
  end

  def test_the_entry_container_answers_to_the_module_short_name
    web = manifest.container_specs(uuid: UUID).first

    assert_includes web.aliases, "example-notes"
    assert_includes web.aliases, "example-notes-web"
  end

  def test_a_non_entry_container_does_not_answer_to_the_module_short_name
    cache = manifest.container_specs(uuid: UUID).last

    refute_includes cache.aliases, "example-notes"
    assert_includes cache.aliases, "example-notes-cache"
  end

  # Specs ----------------------------------------------------------------

  def test_specs_carry_labels_that_identify_the_installation
    web = manifest.container_specs(uuid: UUID).first

    assert_equal UUID, web.labels["siberian.module_uuid"]
    assert_equal "example-notes", web.labels["siberian.module_name"]
    assert_equal "web", web.labels["siberian.service"]
  end

  def test_declared_health_becomes_a_health_value
    web = manifest.container_specs(uuid: UUID).first

    assert_equal "/up", web.health.path
    assert_equal 15, web.health.interval_seconds
  end

  def test_a_container_without_health_has_none
    assert_nil manifest.container_specs(uuid: UUID).last.health
  end

  def test_roles_become_symbols_so_the_driver_never_sees_strings
    roles = manifest.container_specs(uuid: UUID).map(&:role)

    assert_equal %i[http datastore], roles
  end

  # Structural validation ------------------------------------------------

  def test_a_well_formed_manifest_is_valid
    assert manifest.valid?, manifest.structural_errors.join("; ")
  end

  def test_the_reference_module_is_valid
    assert reference_manifest.valid?, reference_manifest.structural_errors.join("; ")
  end

  def test_an_entry_naming_an_unknown_container_is_rejected
    bad = Contracts::Manifest.parse(<<~YAML)
      name: broken
      version: 1.0.0
      containers:
        - service: web
          image: nginx
          role: http
          internal_port: 80
      routes:
        base: /broken
        entry: nope
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "not one of the declared containers"
  end

  def test_an_entry_that_is_not_an_http_container_is_rejected
    bad = Contracts::Manifest.parse(<<~YAML)
      name: broken
      version: 1.0.0
      containers:
        - service: worker
          image: ruby
          role: worker
      routes:
        base: /broken
        entry: worker
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "must name an http container"
  end

  def test_an_entry_without_an_internal_port_is_rejected
    bad = Contracts::Manifest.parse(<<~YAML)
      name: broken
      version: 1.0.0
      containers:
        - service: web
          image: nginx
          role: http
      routes:
        base: /broken
        entry: web
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "must declare an internal_port"
  end

  def test_duplicate_container_services_are_rejected
    bad = Contracts::Manifest.parse(<<~YAML)
      name: broken
      version: 1.0.0
      containers:
        - service: web
          image: nginx
          role: http
          internal_port: 80
        - service: web
          image: nginx
          role: worker
      routes:
        base: /broken
        entry: web
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "duplicate container services"
  end

  def test_a_database_grant_naming_both_a_new_and_an_existing_database_is_rejected
    bad = manifest(<<~YAML)
      permissions:
        databases:
          - name: primary
            target: core.configuration
            access: owner
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "exactly one"
  end

  def test_validate_raises_with_every_error_at_once
    bad = Contracts::Manifest.parse("name: ''\nversion: ''\n")

    error = assert_raises(Contracts::Manifest::InvalidManifest) { bad.validate! }

    assert_operator error.errors.length, :>=, 3
  end

  # Permissions ----------------------------------------------------------

  def test_requested_permissions_flatten_into_one_operator_facing_list
    requests = reference_manifest.requested_permissions
    kinds = requests.map { |r| r[:kind] }

    assert_includes kinds, "database"
    assert_includes kinds, "storage"
    assert_includes kinds, "mail"
  end

  def test_reading_another_databases_tables_is_never_a_routine_request
    requests = reference_manifest.requested_permissions
    owner = requests.find { |r| r[:summary].include?("owner") }
    reader = requests.find { |r| r[:summary].start_with?("read") }

    assert_equal :high, owner[:severity], "owning a database is the strongest database request"
    assert_equal :medium, reader[:severity],
                 "reading somebody else data is never routine, whatever the verb"
    assert reader[:audited], "a cross-database grant is audited, and the review screen should say so"
  end

  def test_a_cross_database_request_names_the_tables_and_the_reason
    reader = reference_manifest.requested_permissions.find { |r| r[:summary].start_with?("read") }

    assert_includes reader[:detail], "settings"
    assert_includes reader[:detail], "feature_flags"
    assert_includes reader[:detail], "locale"
  end

  def test_a_target_grant_with_no_tables_is_rejected
    bad = manifest(<<~YAML)
      permissions:
        databases:
          - target: core.configuration
            access: read
            reason: because
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "names no tables"
  end

  def test_a_target_grant_with_no_reason_is_rejected
    bad = manifest(<<~YAML)
      permissions:
        databases:
          - target: core.configuration
            access: read
            tables: [settings]
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "gives no reason"
  end

  def test_a_module_cannot_claim_to_own_somebody_elses_database
    bad = manifest(<<~YAML)
      permissions:
        databases:
          - target: core.configuration
            access: owner
            tables: [settings]
            reason: because
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "belongs to somebody else"
  end

  def test_owned_and_cross_database_grants_are_told_apart
    assert_equal ["primary"], reference_manifest.owned_database_grants.map { |g| g["name"] }
    assert_equal ["core.configuration"], reference_manifest.cross_database_grants.map { |g| g["target"] }
  end

  def test_a_public_storage_space_is_flagged_above_a_private_one
    public_request = reference_manifest.requested_permissions.find { |r| r[:kind] == "storage" }

    assert_equal :medium, public_request[:severity], "public assets leave the module boundary"
  end

  def test_a_module_with_no_storage_block_requests_no_storage
    assert_empty manifest.storage_spaces
    assert_empty manifest.requested_permissions.select { |r| r[:kind] == "storage" }
  end

  # Capabilities ---------------------------------------------------------

  def relay_manifest
    Contracts::Manifest.load(File.expand_path("../modules/example-relay/module.yml", __dir__))
  end

  def test_system_and_feature_capabilities_are_read_separately
    assert_empty reference_manifest.system_capabilities, "example-notes extends the product, not the core"
    assert_equal 2, reference_manifest.feature_capabilities.length

    assert_equal 1, relay_manifest.system_capabilities.length
    assert_empty relay_manifest.feature_capabilities, "a transport has no page"
  end

  def test_implemented_interfaces_are_listed_for_conflict_detection
    assert_equal ["mail.transport.v1"], relay_manifest.implemented_interfaces
    assert_empty reference_manifest.implemented_interfaces
  end

  def test_the_relay_reference_module_is_valid
    assert relay_manifest.valid?, relay_manifest.structural_errors.join("; ")
  end

  def test_a_system_capability_with_an_area_is_rejected
    bad = manifest(<<~YAML)
      capabilities:
        system:
          - id: x.mail.transport
            interface: mail.transport.v1
            endpoint: /internal/mail
            area: sidebar.entities
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "system capabilities have no UI"
  end

  def test_a_feature_capability_with_an_interface_is_rejected
    bad = manifest(<<~YAML)
      capabilities:
        features:
          - id: x.note.viewer
            area: sidebar.entities
            title: Notes
            path: /notes
            interface: mail.transport.v1
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "that makes it a system capability"
  end

  def test_a_system_capability_without_an_endpoint_is_rejected
    bad = manifest(<<~YAML)
      capabilities:
        system:
          - id: x.mail.transport
            interface: mail.transport.v1
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "needs an endpoint"
  end

  def test_one_module_cannot_declare_the_same_capability_id_twice
    bad = manifest(<<~YAML)
      capabilities:
        features:
          - id: x.note.viewer
            area: a
            title: A
            path: /a
          - id: x.note.viewer
            area: b
            title: B
            path: /b
    YAML

    refute bad.valid?
    assert_includes bad.structural_errors.join, "duplicate capability ids"
  end

  def test_capabilities_are_read_from_the_reference_module
    ids = reference_manifest.feature_capabilities.map { |c| c["id"] }

    assert_includes ids, "example_notes.note.viewer"
    assert_equal "sidebar.entities", reference_manifest.feature_capabilities.first["area"]
  end

  def test_consumed_capabilities_are_read_so_discovery_can_match_them
    assert_equal ["core.user.picker"], reference_manifest.consumed_capabilities.map { |c| c["id"] }
  end

  def test_origin_defaults_to_the_module_name
    assert_equal "example-notes", manifest.origin
  end
end

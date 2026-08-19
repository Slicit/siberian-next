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

  def test_owning_a_database_is_a_higher_severity_request_than_reading_one
    requests = reference_manifest.requested_permissions
    owner = requests.find { |r| r[:summary].include?("owner") }
    reader = requests.find { |r| r[:summary].start_with?("read") }

    assert_equal :high, owner[:severity]
    assert_equal :low, reader[:severity]
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

  def test_capabilities_are_read_from_the_reference_module
    ids = reference_manifest.provided_capabilities.map { |c| c["id"] }

    assert_includes ids, "example_notes.note.viewer"
    assert_equal "sidebar.entities", reference_manifest.provided_capabilities.first["area"]
  end

  def test_consumed_capabilities_are_read_so_discovery_can_match_them
    assert_equal ["core.user.picker"], reference_manifest.consumed_capabilities.map { |c| c["id"] }
  end

  def test_origin_defaults_to_the_module_name
    assert_equal "example-notes", manifest.origin
  end
end

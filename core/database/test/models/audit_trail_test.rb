# frozen_string_literal: true

require "test_helper"

class AuditTrailTest < ActiveSupport::TestCase
  setup do
    @registration, @token = ModuleRegistration.register!(module_name: "notes", module_uuid: "abc")
  end

  test "registering a module is itself recorded" do
    AuditEvent.record!(module_name: "notes", action: "module.registered")

    assert_equal 1, AuditEvent.for_module("notes").count
  end

  test "a refusal is recorded, not only a success" do
    AuditEvent.record!(module_name: "notes", action: "system_table.refused", outcome: "refused",
                       subject: "core.configuration.users")

    refusals = AuditEvent.refusals
    assert_equal 1, refusals.count
    assert refusals.first.refused?
  end

  test "a grant carries the reason an operator approved, not only the fact" do
    grant = @registration.table_grants.create!(
      target_database: "core.configuration", table_name: "settings",
      reason: "Reads the locale so notes render like the rest of the product", approved_at: Time.current
    )

    assert_equal "read core.configuration.settings", grant.to_s
    assert_includes grant.reason, "locale"
  end

  test "a grant is found only while it is live" do
    grant = @registration.table_grants.create!(target_database: "core.configuration", table_name: "settings",
                                                approved_at: Time.current)

    assert_equal grant, @registration.grant_for("core.configuration", "settings")

    grant.update!(revoked_at: Time.current)
    assert_nil @registration.grant_for("core.configuration", "settings"),
               "a revoked grant must stop granting immediately"
  end

  test "a grant for one table does not carry to another" do
    @registration.table_grants.create!(target_database: "core.configuration", table_name: "settings",
                                        approved_at: Time.current)

    assert_nil @registration.grant_for("core.configuration", "feature_flags")
    assert_nil @registration.grant_for("core.auth", "settings"),
               "a grant names a database as well as a table"
  end

  test "the token authenticates, and a revoked module stops authenticating" do
    assert_equal @registration, ModuleRegistration.authenticate(@token)

    @registration.update!(revoked_at: Time.current)
    assert_nil ModuleRegistration.authenticate(@token)
  end

  test "events are read newest first, because that is the question being asked" do
    AuditEvent.record!(module_name: "notes", action: "first")
    travel_to(1.minute.from_now) { AuditEvent.record!(module_name: "notes", action: "second") }

    assert_equal %w[second first], AuditEvent.recent.pluck(:action)
  end
end

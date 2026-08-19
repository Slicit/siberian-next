# frozen_string_literal: true

require "test_helper"

class ProvisioningTest < ActiveSupport::TestCase
  test "database and role names are derived, so the same triple always resolves the same way" do
    first = ProvisionedDatabase.names_for("example-notes", "example.test", "primary")
    second = ProvisionedDatabase.names_for("example-notes", "example.test", "primary")

    assert_equal first, second
    assert first[:database_name].start_with?("sib_example_notes")
    assert first[:role_name].start_with?("sibrole_example_notes")
  end

  test "two domains never share a database" do
    one = ProvisionedDatabase.names_for("notes", "one.test", "primary")
    two = ProvisionedDatabase.names_for("notes", "two.test", "primary")

    refute_equal one[:database_name], two[:database_name]
    refute_equal one[:role_name], two[:role_name]
  end

  test "two logical databases for one module never collide" do
    primary = ProvisionedDatabase.names_for("notes", "one.test", "primary")
    archive = ProvisionedDatabase.names_for("notes", "one.test", "archive")

    refute_equal primary[:database_name], archive[:database_name]
  end

  test "names stay inside the Postgres identifier limit" do
    names = ProvisionedDatabase.names_for(
      "an-extremely-long-module-name-that-goes-on", "a.very.long.domain.example.test", "primary"
    )

    assert_operator names[:database_name].length, :<=, 63
    assert_operator names[:role_name].length, :<=, 63
  end

  test "a module name with dashes becomes a legal identifier" do
    names = ProvisionedDatabase.names_for("example-notes", "one.test", "primary")

    refute_includes names[:database_name], "-"
    refute_includes names[:role_name], "-"
  end

  test "the password is stored encrypted, not in the clear" do
    registration, = ModuleRegistration.register!(module_name: "notes", module_uuid: "abc")
    provisioned = registration.provisioned_databases.create!(
      domain: "one.test", logical_name: "primary", database_name: "sib_notes_a",
      role_name: "sibrole_notes_a", encrypted_password: "hunter2hunter2", state: "ready"
    )

    raw = ProvisionedDatabase.connection.select_value(
      "SELECT encrypted_password FROM provisioned_databases WHERE id = #{provisioned.id}"
    )

    refute_equal "hunter2hunter2", raw, "a stored credential must not be readable from the table"
    assert_equal "hunter2hunter2", provisioned.reload.encrypted_password
  end

  test "the connection details point at the alias, never at a container" do
    registration, = ModuleRegistration.register!(module_name: "notes", module_uuid: "abc")
    provisioned = registration.provisioned_databases.create!(
      domain: "one.test", logical_name: "primary", database_name: "sib_notes_a",
      role_name: "sibrole_notes_a", encrypted_password: "secret-secret", state: "ready"
    )

    details = provisioned.connection_details

    assert_equal "db", details[:host]
    assert_includes details[:url], "@db:"
    refute_includes details[:url], "moduledb"
  end
end

# frozen_string_literal: true

# What the Database service needs to know: which modules exist, which database
# and role belongs to each (module, domain) pair, which system tables a module
# was allowed to read, and every time it did.
class CreateDatabaseSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :module_registrations do |t|
      t.string :module_name, null: false
      t.string :module_uuid, null: false
      t.string :token_digest, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :module_registrations, :module_name, unique: true
    add_index :module_registrations, :token_digest, unique: true

    # One database and one role per (module, domain). The same isolation rule
    # as Storage, so the system has one rule rather than several.
    create_table :provisioned_databases do |t|
      t.references :module_registration, null: false, foreign_key: true
      t.string :domain, null: false
      t.string :logical_name, null: false   # what the manifest called it
      t.string :database_name, null: false  # what Postgres calls it
      t.string :role_name, null: false
      t.string :encrypted_password, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :rotated_at
      t.timestamps
    end
    add_index :provisioned_databases, :database_name, unique: true
    add_index :provisioned_databases, :role_name, unique: true
    add_index :provisioned_databases, %i[module_registration_id domain logical_name],
              unique: true, name: "index_provisioned_databases_on_module_domain_name"

    # Permission to read one named table in a database this module does not own.
    # Table by table, with the reason an operator approved, because "read the
    # configuration store" is not something anyone can meaningfully approve.
    create_table :table_grants do |t|
      t.references :module_registration, null: false, foreign_key: true
      t.string :target_database, null: false
      t.string :table_name, null: false
      t.string :access, null: false, default: "read"
      t.text :reason
      t.datetime :approved_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :table_grants, %i[module_registration_id target_database table_name],
              unique: true, name: "index_table_grants_on_module_and_table"

    # The audit trail. Append-only by convention and by the absence of any code
    # that updates it: a trail somebody can edit is not a trail.
    #
    # Every credential issued and every system table read lands here. That is
    # the point of routing those reads through this service rather than handing
    # out a connection: a direct connection is unobservable.
    create_table :audit_events do |t|
      t.string :module_name, null: false
      t.string :domain
      t.string :action, null: false
      t.string :subject
      t.integer :row_count
      t.string :outcome, null: false, default: "allowed"
      t.text :detail
      t.json :context, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :audit_events, %i[module_name occurred_at]
    add_index :audit_events, :action
    add_index :audit_events, :occurred_at
  end
end

# frozen_string_literal: true

# What the Storage service needs to know: which modules exist, what they were
# granted, and which bucket holds their files for a given domain.
class CreateStorageSchema < ActiveRecord::Migration[8.1]
  def change
    # Registered by the Orchestrator at install time. The token is how a module
    # proves who it is; only its digest is kept, because a stolen table should
    # not be a stolen identity.
    create_table :module_registrations do |t|
      t.string :module_name, null: false
      t.string :module_uuid, null: false
      t.string :token_digest, null: false
      t.json :spaces, null: false, default: []
      t.integer :quota_mb, null: false, default: 512
      t.integer :tmp_ttl_hours, null: false, default: 168
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :module_registrations, :module_name, unique: true
    add_index :module_registrations, :token_digest, unique: true

    # One bucket per (module, domain). The same isolation rule as the Database
    # service, so the system has one rule rather than two.
    create_table :buckets do |t|
      t.references :module_registration, null: false, foreign_key: true
      t.string :domain, null: false
      t.string :name, null: false
      t.string :bucket_id
      t.string :access_key_id
      t.string :secret_access_key
      t.bigint :bytes_used, null: false, default: 0
      t.timestamps
    end
    add_index :buckets, :name, unique: true
    add_index :buckets, %i[module_registration_id domain], unique: true
  end
end

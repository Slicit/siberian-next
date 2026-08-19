# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_19_170000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.json "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "detail"
    t.string "domain"
    t.string "module_name", null: false
    t.datetime "occurred_at", null: false
    t.string "outcome", default: "allowed", null: false
    t.integer "row_count"
    t.string "subject"
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_audit_events_on_action"
    t.index ["module_name", "occurred_at"], name: "index_audit_events_on_module_name_and_occurred_at"
    t.index ["occurred_at"], name: "index_audit_events_on_occurred_at"
  end

  create_table "module_registrations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "module_name", null: false
    t.string "module_uuid", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["module_name"], name: "index_module_registrations_on_module_name", unique: true
    t.index ["token_digest"], name: "index_module_registrations_on_token_digest", unique: true
  end

  create_table "provisioned_databases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "database_name", null: false
    t.string "domain", null: false
    t.string "encrypted_password", null: false
    t.string "logical_name", null: false
    t.bigint "module_registration_id", null: false
    t.string "role_name", null: false
    t.datetime "rotated_at"
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["database_name"], name: "index_provisioned_databases_on_database_name", unique: true
    t.index ["module_registration_id", "domain", "logical_name"], name: "index_provisioned_databases_on_module_domain_name", unique: true
    t.index ["module_registration_id"], name: "index_provisioned_databases_on_module_registration_id"
    t.index ["role_name"], name: "index_provisioned_databases_on_role_name", unique: true
  end

  create_table "table_grants", force: :cascade do |t|
    t.string "access", default: "read", null: false
    t.datetime "approved_at"
    t.datetime "created_at", null: false
    t.bigint "module_registration_id", null: false
    t.text "reason"
    t.datetime "revoked_at"
    t.string "table_name", null: false
    t.string "target_database", null: false
    t.datetime "updated_at", null: false
    t.index ["module_registration_id", "target_database", "table_name"], name: "index_table_grants_on_module_and_table", unique: true
    t.index ["module_registration_id"], name: "index_table_grants_on_module_registration_id"
  end

  add_foreign_key "provisioned_databases", "module_registrations"
  add_foreign_key "table_grants", "module_registrations"
end

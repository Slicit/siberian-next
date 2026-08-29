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

ActiveRecord::Schema[8.1].define(version: 2026_08_29_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "app_password_resets", force: :cascade do |t|
    t.bigint "app_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "requested_ip"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.index ["app_user_id", "created_at"], name: "index_app_password_resets_on_app_user_id_and_created_at"
    t.index ["app_user_id"], name: "index_app_password_resets_on_app_user_id"
    t.index ["token_digest"], name: "index_app_password_resets_on_token_digest", unique: true
  end

  create_table "app_sessions", force: :cascade do |t|
    t.bigint "app_user_id", null: false
    t.datetime "created_at", null: false
    t.string "device_id"
    t.string "device_name"
    t.datetime "expires_at", null: false
    t.string "ip_address"
    t.datetime "last_seen_at"
    t.string "platform"
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["app_user_id", "device_id"], name: "index_app_sessions_on_app_user_id_and_device_id"
    t.index ["app_user_id", "expires_at"], name: "index_app_sessions_on_app_user_id_and_expires_at"
    t.index ["app_user_id"], name: "index_app_sessions_on_app_user_id"
    t.index ["token_digest"], name: "index_app_sessions_on_token_digest", unique: true
  end

  create_table "app_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.boolean "registration_open", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_app_settings_on_domain", unique: true
  end

  create_table "app_users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "domain", null: false
    t.string "email", null: false
    t.datetime "last_seen_at"
    t.string "name"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.string "verification_digest"
    t.datetime "verified_at"
    t.index "domain, lower((email)::text)", name: "index_app_users_on_domain_and_email", unique: true
    t.index ["domain", "active"], name: "index_app_users_on_domain_and_active"
    t.index ["verification_digest"], name: "index_app_users_on_verification_digest", unique: true
  end

  create_table "auth_attempts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.string "identifier", null: false
    t.string "ip_address"
    t.string "kind", null: false
    t.index ["created_at"], name: "index_auth_attempts_on_created_at"
    t.index ["kind", "identifier", "created_at"], name: "index_auth_attempts_on_kind_and_identifier_and_created_at"
    t.index ["kind", "ip_address", "created_at"], name: "index_auth_attempts_on_kind_and_ip_address_and_created_at"
  end

  create_table "permission_grants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "effect", default: "allow", null: false
    t.bigint "granted_by_id"
    t.string "permission", null: false
    t.string "reason"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["granted_by_id"], name: "index_permission_grants_on_granted_by_id"
    t.index ["user_id", "permission", "effect"], name: "index_permission_grants_on_user_permission_effect", unique: true
    t.index ["user_id"], name: "index_permission_grants_on_user_id"
  end

  create_table "role_assignments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "granted_by_id"
    t.bigint "role_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["granted_by_id"], name: "index_role_assignments_on_granted_by_id"
    t.index ["role_id"], name: "index_role_assignments_on_role_id"
    t.index ["user_id", "role_id"], name: "index_role_assignments_on_user_id_and_role_id", unique: true
    t.index ["user_id"], name: "index_role_assignments_on_user_id"
  end

  create_table "roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description"
    t.string "name", null: false
    t.json "permissions", default: [], null: false
    t.boolean "seeded", default: false, null: false
    t.json "seeded_permissions", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_roles_on_name", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.datetime "expires_at", null: false
    t.string "ip_address"
    t.json "permissions", default: {}, null: false
    t.integer "permissions_version", default: 0, null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id", "expires_at"], name: "index_sessions_on_user_id_and_expires_at"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "user_password_resets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "requested_ip"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.bigint "user_id", null: false
    t.index ["token_digest"], name: "index_user_password_resets_on_token_digest", unique: true
    t.index ["user_id", "created_at"], name: "index_user_password_resets_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_user_password_resets_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "email", null: false
    t.datetime "last_seen_at"
    t.string "name"
    t.boolean "operator", default: false, null: false
    t.boolean "otp_required", default: false, null: false
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.integer "permissions_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_users_on_active"
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "app_password_resets", "app_users"
  add_foreign_key "app_sessions", "app_users"
  add_foreign_key "permission_grants", "users"
  add_foreign_key "permission_grants", "users", column: "granted_by_id"
  add_foreign_key "role_assignments", "roles"
  add_foreign_key "role_assignments", "users"
  add_foreign_key "role_assignments", "users", column: "granted_by_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "user_password_resets", "users"
end

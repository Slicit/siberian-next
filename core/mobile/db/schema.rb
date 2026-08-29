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

ActiveRecord::Schema[8.1].define(version: 2026_08_29_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "app_capabilities", force: :cascade do |t|
    t.string "capability", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.bigint "mobile_app_id", null: false
    t.json "settings", default: {}, null: false
    t.string "source", default: "operator", null: false
    t.datetime "updated_at", null: false
    t.index ["mobile_app_id", "capability"], name: "index_app_capabilities_on_mobile_app_id_and_capability", unique: true
    t.index ["mobile_app_id"], name: "index_app_capabilities_on_mobile_app_id"
  end

  create_table "build_attempts", force: :cascade do |t|
    t.datetime "attempted_at", null: false
    t.bigint "build_id", null: false
    t.datetime "created_at", null: false
    t.text "detail"
    t.integer "duration_ms"
    t.integer "number", null: false
    t.string "outcome", null: false
    t.datetime "updated_at", null: false
    t.index ["build_id", "number"], name: "index_build_attempts_on_build_id_and_number", unique: true
    t.index ["build_id"], name: "index_build_attempts_on_build_id"
  end

  create_table "builds", force: :cascade do |t|
    t.datetime "acknowledged_at"
    t.bigint "artifact_bytes"
    t.string "artifact_path"
    t.integer "attempts", default: 0, null: false
    t.datetime "claimed_at"
    t.json "configuration", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.datetime "finished_at"
    t.string "last_error"
    t.text "log"
    t.bigint "mobile_app_id", null: false
    t.datetime "next_attempt_at"
    t.string "platform", null: false
    t.string "requested_by"
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["mobile_app_id", "created_at"], name: "index_builds_on_mobile_app_id_and_created_at"
    t.index ["mobile_app_id"], name: "index_builds_on_mobile_app_id"
    t.index ["state", "next_attempt_at"], name: "index_builds_on_state_and_next_attempt_at"
  end

  create_table "mobile_apps", force: :cascade do |t|
    t.integer "build_number", default: 0, null: false
    t.string "bundle_identifier", null: false
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.string "icon_path"
    t.string "name", null: false
    t.string "primary_color"
    t.json "settings", default: {}, null: false
    t.integer "splash_animation_duration_ms", default: 1000, null: false
    t.string "splash_animation_path"
    t.string "splash_background"
    t.string "splash_image_path"
    t.string "theme", default: "daylight", null: false
    t.datetime "updated_at", null: false
    t.string "version", default: "1.0.0", null: false
    t.index ["bundle_identifier"], name: "index_mobile_apps_on_bundle_identifier", unique: true
    t.index ["domain"], name: "index_mobile_apps_on_domain", unique: true
  end

  create_table "module_registrations", force: :cascade do |t|
    t.string "base_route"
    t.datetime "created_at", null: false
    t.string "fallback", default: "webview", null: false
    t.string "module_name", null: false
    t.string "module_uuid", null: false
    t.string "native_entry"
    t.string "origin"
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["module_name"], name: "index_module_registrations_on_module_name", unique: true
    t.index ["token_digest"], name: "index_module_registrations_on_token_digest", unique: true
  end

  create_table "module_requirements", force: :cascade do |t|
    t.string "capability", null: false
    t.datetime "created_at", null: false
    t.bigint "module_registration_id", null: false
    t.datetime "updated_at", null: false
    t.index ["module_registration_id", "capability"], name: "idx_on_module_registration_id_capability_8e547c9ecb", unique: true
    t.index ["module_registration_id"], name: "index_module_requirements_on_module_registration_id"
  end

  create_table "module_screens", force: :cascade do |t|
    t.string "capability", null: false
    t.string "component", null: false
    t.datetime "created_at", null: false
    t.string "icon"
    t.bigint "module_registration_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["module_registration_id", "capability"], name: "index_module_screens_on_module_registration_id_and_capability", unique: true
    t.index ["module_registration_id"], name: "index_module_screens_on_module_registration_id"
  end

  create_table "service_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "service", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["service"], name: "index_service_credentials_on_service", unique: true
  end

  add_foreign_key "app_capabilities", "mobile_apps"
  add_foreign_key "build_attempts", "builds"
  add_foreign_key "builds", "mobile_apps"
  add_foreign_key "module_requirements", "module_registrations"
  add_foreign_key "module_screens", "module_registrations"
end

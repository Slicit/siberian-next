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

ActiveRecord::Schema[8.1].define(version: 2026_08_30_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "activities", force: :cascade do |t|
    t.string "action", null: false
    t.json "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "detail"
    t.bigint "installed_module_id"
    t.string "outcome", default: "started", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_activities_on_created_at"
    t.index ["installed_module_id"], name: "index_activities_on_installed_module_id"
  end

  create_table "alert_conditions", force: :cascade do |t|
    t.datetime "cleared_at"
    t.datetime "created_at", null: false
    t.string "detail"
    t.datetime "firing_since"
    t.string "key", null: false
    t.datetime "notified_at"
    t.integer "occurrences", default: 0, null: false
    t.datetime "pending_since"
    t.string "state", default: "clear", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_alert_conditions_on_key", unique: true
    t.index ["state"], name: "index_alert_conditions_on_state"
  end

  create_table "capabilities", force: :cascade do |t|
    t.json "accepts", default: [], null: false
    t.string "area"
    t.string "capability_id", null: false
    t.datetime "created_at", null: false
    t.string "endpoint"
    t.boolean "exclusive", default: false, null: false
    t.string "icon"
    t.bigint "installed_module_id", null: false
    t.string "interface"
    t.string "kind", default: "feature", null: false
    t.string "path"
    t.integer "position", default: 0, null: false
    t.integer "priority", default: 100, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["area"], name: "index_capabilities_on_area"
    t.index ["capability_id"], name: "index_capabilities_on_capability_id", unique: true
    t.index ["installed_module_id"], name: "index_capabilities_on_installed_module_id"
    t.index ["interface", "priority"], name: "index_capabilities_on_interface_and_priority"
    t.index ["kind"], name: "index_capabilities_on_kind"
  end

  create_table "capability_requests", force: :cascade do |t|
    t.string "capability_id", null: false
    t.datetime "created_at", null: false
    t.bigint "installed_module_id", null: false
    t.boolean "optional", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["installed_module_id", "capability_id"], name: "index_capability_requests_on_module_and_capability", unique: true
    t.index ["installed_module_id"], name: "index_capability_requests_on_installed_module_id"
  end

  create_table "domains", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname", null: false
    t.string "label"
    t.boolean "primary", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["hostname"], name: "index_domains_on_hostname", unique: true
  end

  create_table "grants", force: :cascade do |t|
    t.string "access"
    t.datetime "approved_at"
    t.datetime "created_at", null: false
    t.json "details", default: {}, null: false
    t.bigint "installed_module_id", null: false
    t.string "kind", null: false
    t.string "scope", default: "per_domain", null: false
    t.string "target"
    t.datetime "updated_at", null: false
    t.index ["installed_module_id", "kind"], name: "index_grants_on_installed_module_id_and_kind"
    t.index ["installed_module_id"], name: "index_grants_on_installed_module_id"
  end

  create_table "installed_modules", force: :cascade do |t|
    t.string "base_route"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "entry_service"
    t.datetime "installed_at"
    t.text "last_error"
    t.json "manifest", default: {}, null: false
    t.string "name", null: false
    t.string "network_name"
    t.string "origin"
    t.string "status", default: "pending", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.string "version", null: false
    t.index ["name"], name: "index_installed_modules_on_name", unique: true
    t.index ["status"], name: "index_installed_modules_on_status"
    t.index ["uuid"], name: "index_installed_modules_on_uuid", unique: true
  end

  create_table "module_containers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "engine_id"
    t.string "image", null: false
    t.bigint "installed_module_id", null: false
    t.integer "internal_port"
    t.string "name", null: false
    t.string "role", null: false
    t.string "service", null: false
    t.string "state", default: "absent", null: false
    t.datetime "state_checked_at"
    t.datetime "updated_at", null: false
    t.index ["installed_module_id", "service"], name: "index_module_containers_on_installed_module_id_and_service", unique: true
    t.index ["installed_module_id"], name: "index_module_containers_on_installed_module_id"
    t.index ["name"], name: "index_module_containers_on_name", unique: true
  end

  create_table "provisions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "details", default: {}, null: false
    t.bigint "domain_id", null: false
    t.string "identifier", null: false
    t.bigint "installed_module_id", null: false
    t.string "kind", null: false
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["domain_id"], name: "index_provisions_on_domain_id"
    t.index ["installed_module_id", "domain_id", "kind"], name: "index_provisions_on_module_domain_kind", unique: true
    t.index ["installed_module_id"], name: "index_provisions_on_installed_module_id"
  end

  add_foreign_key "activities", "installed_modules"
  add_foreign_key "capabilities", "installed_modules"
  add_foreign_key "capability_requests", "installed_modules"
  add_foreign_key "grants", "installed_modules"
  add_foreign_key "module_containers", "installed_modules"
  add_foreign_key "provisions", "domains"
  add_foreign_key "provisions", "installed_modules"
end

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

ActiveRecord::Schema[8.1].define(version: 2026_08_19_200000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "buckets", force: :cascade do |t|
    t.string "access_key_id"
    t.string "bucket_id"
    t.bigint "bytes_used", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.bigint "module_registration_id", null: false
    t.string "name", null: false
    t.integer "quota_mb"
    t.string "secret_access_key"
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_buckets_on_domain"
    t.index ["module_registration_id", "domain"], name: "index_buckets_on_module_registration_id_and_domain", unique: true
    t.index ["module_registration_id"], name: "index_buckets_on_module_registration_id"
    t.index ["name"], name: "index_buckets_on_name", unique: true
  end

  create_table "domain_quotas", force: :cascade do |t|
    t.bigint "bytes_used", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "default_bucket_quota_mb"
    t.string "domain", null: false
    t.integer "quota_mb"
    t.datetime "recalculated_at"
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_domain_quotas_on_domain", unique: true
  end

  create_table "module_registrations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "module_name", null: false
    t.string "module_uuid", null: false
    t.integer "quota_mb", default: 512, null: false
    t.datetime "revoked_at"
    t.json "spaces", default: [], null: false
    t.integer "tmp_ttl_hours", default: 168, null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["module_name"], name: "index_module_registrations_on_module_name", unique: true
    t.index ["token_digest"], name: "index_module_registrations_on_token_digest", unique: true
  end

  create_table "storage_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "default_bucket_quota_mb", default: 512, null: false
    t.integer "default_domain_quota_mb"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "buckets", "module_registrations"
end

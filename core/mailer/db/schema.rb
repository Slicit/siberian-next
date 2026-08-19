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

ActiveRecord::Schema[8.1].define(version: 2026_08_19_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "delivery_attempts", force: :cascade do |t|
    t.datetime "attempted_at", null: false
    t.datetime "created_at", null: false
    t.text "detail"
    t.integer "duration_ms"
    t.bigint "message_id", null: false
    t.integer "number", null: false
    t.string "outcome", null: false
    t.string "transport"
    t.datetime "updated_at", null: false
    t.index ["message_id", "number"], name: "index_delivery_attempts_on_message_id_and_number", unique: true
    t.index ["message_id"], name: "index_delivery_attempts_on_message_id"
  end

  create_table "messages", force: :cascade do |t|
    t.datetime "acknowledged_at"
    t.integer "attempts", default: 0, null: false
    t.string "bcc"
    t.string "cc"
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.string "from"
    t.json "headers", default: {}, null: false
    t.text "html_body"
    t.string "idempotency_key"
    t.text "last_error"
    t.integer "max_attempts", default: 6, null: false
    t.bigint "module_registration_id", null: false
    t.datetime "next_attempt_at"
    t.string "reply_to"
    t.datetime "sent_at"
    t.string "state", default: "queued", null: false
    t.string "subject", null: false
    t.text "text_body"
    t.string "to", null: false
    t.string "transport"
    t.datetime "updated_at", null: false
    t.index ["module_registration_id", "acknowledged_at"], name: "index_messages_on_module_registration_id_and_acknowledged_at"
    t.index ["module_registration_id", "idempotency_key"], name: "index_messages_on_module_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["module_registration_id", "state"], name: "index_messages_on_module_registration_id_and_state"
    t.index ["module_registration_id"], name: "index_messages_on_module_registration_id"
    t.index ["state", "next_attempt_at"], name: "index_messages_on_state_and_next_attempt_at"
  end

  create_table "module_registrations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "daily_limit"
    t.string "module_name", null: false
    t.string "module_uuid", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["module_name"], name: "index_module_registrations_on_module_name", unique: true
    t.index ["token_digest"], name: "index_module_registrations_on_token_digest", unique: true
  end

  add_foreign_key "delivery_attempts", "messages"
  add_foreign_key "messages", "module_registrations"
end

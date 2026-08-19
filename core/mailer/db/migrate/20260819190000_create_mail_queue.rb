# frozen_string_literal: true

# The mail queue.
#
# The table is the source of truth, not a cache of one. The API answers per
# module and per domain, acknowledgement is durable state, and "what happened to
# this message" is the question the whole feature exists to answer. Putting
# scheduling somewhere else as well would mean two stores that can disagree, and
# the two ways they disagree are a message sent twice and a message lost.
class CreateMailQueue < ActiveRecord::Migration[8.1]
  def change
    create_table :module_registrations do |t|
      t.string :module_name, null: false
      t.string :module_uuid, null: false
      t.string :token_digest, null: false
      t.integer :daily_limit
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :module_registrations, :module_name, unique: true
    add_index :module_registrations, :token_digest, unique: true

    create_table :messages do |t|
      t.references :module_registration, null: false, foreign_key: true
      t.string :domain, null: false

      t.string :to, null: false
      t.string :cc
      t.string :bcc
      t.string :from
      t.string :reply_to
      t.string :subject, null: false
      t.text :text_body
      t.text :html_body
      t.json :headers, null: false, default: {}

      # queued, sending, sent, failed, dead, cancelled
      t.string :state, null: false, default: "queued"
      t.integer :attempts, null: false, default: 0
      t.integer :max_attempts, null: false, default: 6
      t.datetime :next_attempt_at
      t.datetime :sent_at
      t.text :last_error
      t.string :transport

      # A module has to have seen a terminal outcome before it stops being
      # reported. A module that crashes between "the send failed" and acting on
      # it has otherwise lost the only copy of that fact.
      t.datetime :acknowledged_at

      # Supplied by the caller. Enqueuing the same key twice is one message, so
      # a module retrying its own request does not send twice.
      t.string :idempotency_key

      t.timestamps
    end

    # The claim query: due work, oldest first, one worker at a time.
    add_index :messages, %i[state next_attempt_at]
    add_index :messages, %i[module_registration_id state]
    add_index :messages, %i[module_registration_id acknowledged_at]
    add_index :messages, %i[module_registration_id idempotency_key],
              unique: true, where: "idempotency_key IS NOT NULL",
              name: "index_messages_on_module_and_idempotency_key"

    # One row per try, so "why did this take four hours" has an answer rather
    # than a guess.
    create_table :delivery_attempts do |t|
      t.references :message, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :outcome, null: false
      t.string :transport
      t.integer :duration_ms
      t.text :detail
      t.datetime :attempted_at, null: false
      t.timestamps
    end
    add_index :delivery_attempts, %i[message_id number], unique: true
  end
end

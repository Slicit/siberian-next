# frozen_string_literal: true

# The Mailer was built for modules, and the first thing in the core that needs
# to send mail is Auth, sending somebody a way back into their account.
#
# Registering Auth as a module would have cost nothing and been wrong: "module"
# means the packaged third-party unit everywhere else in this system, and a
# schema where it also means "a core service" is a word that has to be
# explained every time somebody reads it.
#
# So a message belongs to a sender, and a sender is either a module or a named
# core service. Everything downstream of that (the per-sender isolation, the
# daily limit, the retry, the queue) is unchanged, because none of it ever
# cared which kind it was.
class AllowCoreSenders < ActiveRecord::Migration[8.1]
  def up
    change_column_null :messages, :module_registration_id, true
    add_column :messages, :core_sender, :string

    # One or the other, never both and never neither. Expressed in the database
    # rather than only in a validation, because a message with no sender has
    # nowhere to be listed and nothing to be isolated by, and that is worth
    # being unable to write rather than merely unlikely.
    execute(<<~SQL.squish)
      ALTER TABLE messages
      ADD CONSTRAINT messages_have_exactly_one_sender
      CHECK (
        (module_registration_id IS NOT NULL AND core_sender IS NULL)
        OR (module_registration_id IS NULL AND core_sender IS NOT NULL)
      )
    SQL

    add_index :messages, %i[core_sender domain state]
    add_index :messages, %i[core_sender idempotency_key], unique: true,
              where: "core_sender IS NOT NULL AND idempotency_key IS NOT NULL",
              name: "index_messages_on_core_sender_and_idempotency_key"
  end

  def down
    remove_index :messages, name: "index_messages_on_core_sender_and_idempotency_key"
    remove_index :messages, %i[core_sender domain state]
    execute("ALTER TABLE messages DROP CONSTRAINT messages_have_exactly_one_sender")
    # Anything a core service sent cannot be expressed by the old schema, so it
    # goes rather than being reassigned to a module that did not send it.
    execute("DELETE FROM messages WHERE core_sender IS NOT NULL")
    remove_column :messages, :core_sender
    change_column_null :messages, :module_registration_id, false
  end
end

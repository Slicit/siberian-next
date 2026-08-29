# frozen_string_literal: true

# A stable name for a person, for modules to key their rows by.
#
# Modules key by email address today. `demo-tasks` has `user_email text NOT
# NULL`, `example-push` has two tables keyed on it, `example-notes` inserts by
# it. That has two consequences, one already worked around and one not:
#
#   Ending an account cannot free the address, because the next person to claim
#   it would open the app and find the previous person's tasks waiting. That is
#   why `deleted_at` exists rather than a real delete.
#
#   Changing an address would orphan everything the person ever made, in every
#   module at once, with nothing anywhere reporting it. Nobody can change one
#   yet, which is the only reason this has not happened.
#
# An address is how somebody signs in. It was never meant to be who they are.
#
# Not the primary key, for a reason worth stating: `users` and `app_users` are
# separate tables with separate sequences, so operator 7 and app user 7 both
# exist. A module keying by a bare id would mix their rows together, and the
# first symptom would be an operator opening a module and seeing somebody
# else's data. The prefix makes that structurally impossible and makes a value
# self-describing wherever it turns up.
class AddSubjectToIdentities < ActiveRecord::Migration[8.1]
  def up
    add_column :app_users, :subject, :string
    add_column :users, :subject, :string

    # Backfilled in the migration rather than lazily, because a null subject is
    # a person a module cannot key by, and there is no useful behaviour to fall
    # back to.
    say_with_time "naming existing identities" do
      backfill("app_users", "au")
      backfill("users", "cu")
    end

    change_column_null :app_users, :subject, false
    change_column_null :users, :subject, false

    add_index :app_users, :subject, unique: true
    add_index :users, :subject, unique: true
  end

  def down
    remove_column :app_users, :subject
    remove_column :users, :subject
  end

  private

  # gen_random_uuid is in Postgres itself since 13, so this needs no extension
  # and no round trip per row.
  def backfill(table, prefix)
    execute(<<~SQL.squish)
      UPDATE #{table}
         SET subject = '#{prefix}_' || replace(gen_random_uuid()::text, '-', '')
       WHERE subject IS NULL
    SQL
  end
end

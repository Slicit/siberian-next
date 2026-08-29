# frozen_string_literal: true

# An account the person themselves ended.
#
# Distinct from `deactivated_at`, which is an operator suspending somebody and
# is meant to be undone. This is final, and the row survives it for a reason
# worth writing down.
#
# Every module keys its own rows by the person's email address. `demo-tasks` has
# `user_email text NOT NULL`; `example-notes` inserts by it. So if deleting an
# account freed the address, the next person to sign up with the same one would
# open the app and find the previous person's tasks, notes and notifications
# waiting for them. That is a worse outcome than not being able to reuse an
# address.
#
# So the row stays and keeps its address, which keeps it claimed. What goes is
# the ability to sign in, every session, and the password.
#
# The durable fix landed in AddSubjectToIdentities: modules key by the subject
# the core issues rather than by an address. This is still needed, for a
# smaller reason. Reads are by subject, so a reused address shows the new
# person nothing of the old one; what is unsafe is each module's backfill,
# which finds its own old rows by address and would hand them to whoever took
# it next. The address can be freed once no module is still running one.
class AddDeletedAtToAppUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :app_users, :deleted_at, :datetime
    add_index :app_users, %i[domain deleted_at]
  end
end

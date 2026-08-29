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
# The durable fix is not here: modules should key by the stable id the identity
# already carries rather than by an address that can change hands. That is a
# change to every module and to the contract, and until it happens this is the
# safe shape.
class AddDeletedAtToAppUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :app_users, :deleted_at, :datetime
    add_index :app_users, %i[domain deleted_at]
  end
end

# frozen_string_literal: true

# The person an app is for.
#
# Separate from `users` rather than a flag on it, for three reasons that are
# each enough on their own.
#
# The uniqueness rule is different. A core account is one person across the
# whole system, so its email is unique everywhere. An app account belongs to one
# domain's app, and the same address signing up to two domains is two unrelated
# people who happen to share a mailbox. Those two rules cannot live on one
# column.
#
# The blast radius is different. A core account can be made an operator. An app
# account must never be one, and the cheapest way to guarantee that is for the
# operator machinery to have nothing to attach to: no roles table, no grants
# table, no operator column.
#
# The session is different. A browser session is short and re-established by
# signing in again. A phone is signed in for months on each of several devices,
# and each of those has to be nameable and revocable on its own.
class CreateAppUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :app_users do |t|
      # The domain is the tenant. There is one app per domain today, and when
      # that stops being true this is the column that grows a sibling rather
      # than the table that gets replaced.
      t.string :domain, null: false
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :name

      t.boolean :active, null: false, default: true
      t.datetime :deactivated_at
      t.datetime :last_seen_at

      t.timestamps
    end

    # The whole point, expressed where it cannot be forgotten: unique within a
    # domain and free across domains. Lowercased in the index because the model
    # normalises on the way in and an index that disagrees with the model is a
    # duplicate waiting for the first mixed-case signup.
    add_index :app_users, "domain, lower(email)", unique: true,
              name: "index_app_users_on_domain_and_email"
    add_index :app_users, %i[domain active]

    # One row per device, not per sign-in.
    #
    # Kept apart from `sessions` on purpose. A row in `sessions` belongs to a
    # core account and carries a resolved permission set; a row here belongs to
    # an app account and carries a device. Sharing one table would mean every
    # query that means "a signed-in operator" would have to remember to say so.
    create_table :app_sessions do |t|
      t.references :app_user, null: false, foreign_key: true
      t.string :token_digest, null: false

      # Supplied by the app and stable across reinstalls of a session, so
      # signing in again from the same phone replaces that device rather than
      # leaving a list of ghosts nobody can tell apart.
      t.string :device_id
      t.string :device_name
      t.string :platform

      t.string :user_agent
      t.string :ip_address

      t.datetime :expires_at, null: false
      t.datetime :last_seen_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :app_sessions, :token_digest, unique: true
    add_index :app_sessions, %i[app_user_id expires_at]
    add_index :app_sessions, %i[app_user_id device_id]

    # Whether a stranger may create an account on this domain.
    #
    # Closed by default, and deliberately: a switch that defaults to open would
    # mean every domain that ever installs this accepts signups from anyone
    # before its operator has been asked. Turning it on is one toggle; turning
    # it back on after finding out is not.
    create_table :app_settings do |t|
      t.string :domain, null: false
      t.boolean :registration_open, null: false, default: false
      t.timestamps
    end

    add_index :app_settings, :domain, unique: true
  end
end

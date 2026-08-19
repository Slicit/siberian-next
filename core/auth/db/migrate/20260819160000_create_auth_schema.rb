# frozen_string_literal: true

# Out of the box authentication for the whole system: the core, the Base App,
# and every module. A module never implements a login screen.
class CreateAuthSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :name
      t.string :password_digest, null: false
      t.boolean :operator, null: false, default: false
      t.string :otp_secret
      t.boolean :otp_required, null: false, default: false
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :users, :email, unique: true

    # Opaque session tokens rather than a signed cookie carrying claims: a
    # session that cannot be revoked is not a session, it is a bearer grant with
    # an expiry, and revoking one is the first thing anyone asks for.
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.string :domain, null: false
      t.string :user_agent
      t.string :ip_address
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :sessions, :token_digest, unique: true
    add_index :sessions, %i[user_id expires_at]
  end
end

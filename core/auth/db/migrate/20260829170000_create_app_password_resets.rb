# frozen_string_literal: true

# A way back into an account, and a limit on how often anybody may ask for one.
#
# Two tables because they answer different questions and outlive each other
# differently: a reset is a single-use grant with an owner, and an attempt is a
# counter with no owner at all, since most of what it counts is somebody who
# does not have an account.
class CreateAppPasswordResets < ActiveRecord::Migration[8.1]
  def change
    create_table :app_password_resets do |t|
      t.references :app_user, null: false, foreign_key: true
      t.string :token_digest, null: false

      t.datetime :expires_at, null: false
      # Single use. Recorded rather than deleted, so a second click on the same
      # link can say "that link has been used" instead of "that link is not
      # real", which is the difference between a person understanding what
      # happened and a person trying again.
      t.datetime :used_at
      t.string :requested_ip

      t.timestamps
    end

    add_index :app_password_resets, :token_digest, unique: true
    add_index :app_password_resets, %i[app_user_id created_at]

    # What has been tried recently, by whom, against what.
    #
    # Deliberately not attached to an account: most sign-in attempts worth
    # counting are against an address that does not exist, and a counter that
    # only exists once somebody has an account cannot see those at all.
    create_table :auth_attempts do |t|
      # "sign-in" or "reset". One table rather than two, because the question
      # asked of it is the same and the window differs only by a number.
      t.string :kind, null: false
      # The email asked about, lowercased, and the address it was asked from.
      # Both are counted, because limiting only by address lets one attacker
      # spread across a botnet, and limiting only by email lets one address
      # walk a list.
      t.string :identifier, null: false
      t.string :ip_address

      t.string :domain, null: false
      t.datetime :created_at, null: false
    end

    add_index :auth_attempts, %i[kind identifier created_at]
    add_index :auth_attempts, %i[kind ip_address created_at]
    # Swept rather than kept. Nothing here is evidence, it is a counter, and a
    # table that only grows becomes the reason sign-in is slow.
    add_index :auth_attempts, :created_at
  end
end

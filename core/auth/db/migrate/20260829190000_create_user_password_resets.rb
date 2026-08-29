# frozen_string_literal: true

# A way back into a core account.
#
# App accounts got one first, because they had no other route in at all: an app
# user who forgets a password is a customer who leaves. A core account has an
# operator who can reset it by hand, which made this less urgent and not less
# necessary. The one-operator installation has nobody to ask.
#
# A second table rather than one polymorphic one. A reset row is inert (it
# grants nothing but "set this account's password") so sharing would be safe
# enough, and the reason not to is the same reason `app_users` is its own table:
# every place the two kinds of account meet is a place a bug can hand one the
# other's powers, and there is no need for another.
#
# The behaviour is shared instead. `ResetToken` is one implementation over two
# tables, which is where the duplication would actually have hurt.
class CreateUserPasswordResets < ActiveRecord::Migration[8.1]
  def change
    create_table :user_password_resets do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false

      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.string :requested_ip

      t.timestamps
    end

    add_index :user_password_resets, :token_digest, unique: true
    add_index :user_password_resets, %i[user_id created_at]

    # Whether an app account has proved it can read the address it signed up
    # with.
    #
    # Nullable and not enforced anywhere yet, deliberately. Blocking sign-in on
    # it would mean a broken mail transport locks every new account out of a
    # product that was working, which is a worse failure than an unverified
    # address. It is recorded, shown to an operator, and reported in the
    # identity so a module can decide for itself.
    add_column :app_users, :verified_at, :datetime
    add_column :app_users, :verification_digest, :string
    add_index :app_users, :verification_digest, unique: true
  end
end

# frozen_string_literal: true

# Roles, grants, and the machinery that makes checking them free.
#
# The performance question in a fine-grained model is not how fast one check is,
# it is how many checks a page makes. A sidebar with twelve capabilities asks
# twelve questions before it renders. So permissions are resolved once, stored
# flat on the session, and invalidated by a version stamp rather than by hunting
# down sessions.
class CreateAccessControl < ActiveRecord::Migration[8.1]
  def change
    create_table :roles do |t|
      t.string :name, null: false
      t.string :description
      t.json :permissions, null: false, default: []
      # Seeded roles can be edited and deleted like any other. The flag only
      # marks where they came from, so the UI can say so.
      t.boolean :seeded, null: false, default: false
      t.timestamps
    end
    add_index :roles, :name, unique: true

    create_table :role_assignments do |t|
      t.references :user, null: false, foreign_key: true
      t.references :role, null: false, foreign_key: true
      t.references :granted_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :role_assignments, %i[user_id role_id], unique: true

    # A permission attached to one person, outside any role. Both directions:
    # "this one extra thing" and, more usefully, "an operator except for this".
    create_table :permission_grants do |t|
      t.references :user, null: false, foreign_key: true
      t.string :permission, null: false
      t.string :effect, null: false, default: "allow"
      t.string :reason
      t.references :granted_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :permission_grants, %i[user_id permission effect], unique: true,
                                  name: "index_permission_grants_on_user_permission_effect"

    change_table :users, bulk: true do |t|
      # Bumped whenever anything that could change this person's answers
      # changes. A session carries the version it resolved at, so staleness is a
      # comparison rather than a broadcast.
      t.integer :permissions_version, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.datetime :deactivated_at
    end

    change_table :sessions, bulk: true do |t|
      t.json :permissions, null: false, default: {}
      t.integer :permissions_version, null: false, default: 0
    end

    add_index :users, :active
  end
end

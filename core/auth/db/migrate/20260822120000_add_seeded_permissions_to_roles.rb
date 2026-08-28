# frozen_string_literal: true

# What the catalogue granted this role the last time it was seeded.
#
# Without it, reconciling a seeded role has to choose between overwriting an
# operator's edits and never delivering a permission added after the role was
# created. With it, the difference between the catalogue now and this snapshot
# is exactly the set of permissions that did not exist when the operator last
# had an opinion, and nothing else is touched.
class AddSeededPermissionsToRoles < ActiveRecord::Migration[8.1]
  def up
    add_column :roles, :seeded_permissions, :json, default: [], null: false

    # A role seeded before this column existed has no record of what it was
    # handed, so the best available assumption is that it was handed what it
    # currently holds.
    #
    # The alternative, backfilling from today's catalogue, would make the first
    # reconcile a no-op and leave exactly the bug this exists to fix:
    # `core.storage.manage` shipped after the operator role was seeded, so it
    # is in the catalogue and not in the role, and only a snapshot that omits
    # it too will ever deliver it.
    #
    # The cost is one-off and worth stating: a permission an operator removed
    # on purpose before this migration ran looks identical to one that was
    # never offered, and comes back on the first reconcile. Removals made after
    # this point survive, because from here the snapshot is real.
    up_only do
      execute(<<~SQL.squish)
        UPDATE roles
        SET seeded_permissions = permissions
        WHERE seeded = TRUE
      SQL
    end
  end

  def down
    remove_column :roles, :seeded_permissions
  end
end

# frozen_string_literal: true

# Capabilities come in two kinds, because they extend different things.
#
#   system   extends the core: mail transport, authentication, cache. Reached
#            by the core through a named interface, has no UI and no area.
#   feature  extends the product: a page or fragment the Base App lists in a
#            named area.
#
# One table rather than two: they share an id namespace, they are declared in
# the same manifest block, and discovery matches consumes against both.
class SplitCapabilityKinds < ActiveRecord::Migration[8.1]
  def change
    change_table :capabilities, bulk: true do |t|
      t.string :kind, null: false, default: "feature"
      t.string :interface
      t.string :endpoint
      t.integer :priority, null: false, default: 100
      t.boolean :exclusive, null: false, default: false
    end

    # area and path only mean something for feature capabilities, so they stop
    # being required at the database level.
    change_column_null :capabilities, :area, true
    change_column_null :capabilities, :path, true

    add_index :capabilities, :kind
    # Resolving an interface means "who implements this, best first", which is
    # the only query the core makes against system capabilities.
    add_index :capabilities, %i[interface priority]
  end
end

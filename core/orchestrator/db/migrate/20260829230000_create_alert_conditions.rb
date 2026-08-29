# frozen_string_literal: true

# One row per thing that can be wrong, and what has been said about it.
#
# The table exists because of the requirement rather than in spite of it: alerts
# have to be worth reading, and the way alerting becomes worthless is sending
# the same true statement every time somebody asks. Without somewhere to record
# what was already said, every scan is a fresh discovery and a disk that has
# been full since Tuesday reports itself every fifteen minutes until nobody
# reads any of it.
#
# So a condition is a row with a memory. It fires once when it starts, clears
# once when it stops, and says nothing in between however often it is asked.
class CreateAlertConditions < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_conditions do |t|
      # Stable across scans, because it is what "the same problem" means:
      # `storage.siberian.test`, `sweep.red`, `mail.worker.stalled`.
      t.string :key, null: false
      t.string :state, null: false, default: "clear"
      t.string :detail

      # First seen, not first reported. A condition has to hold across two
      # scans before anything is sent, so that a service restarting during a
      # deploy is not an incident.
      t.datetime :pending_since
      t.datetime :firing_since
      t.datetime :notified_at
      t.datetime :cleared_at

      t.timestamps
    end

    add_index :alert_conditions, :key, unique: true
    add_index :alert_conditions, :state
  end
end

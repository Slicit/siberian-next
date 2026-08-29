# frozen_string_literal: true

# How many times this has been a problem.
#
# Added because keying an alert email on `firing_since` at second resolution
# meant two occurrences inside one second shared a key and the second was
# deduplicated away. In production scans are a quarter of an hour apart so that
# could not happen; in a test it happens every time, which is the sort of
# difference that hides a real edge until it does not.
#
# It is worth having for its own sake as well. "This is the fourth time this
# week" is a different sentence from "this is happening", and only one of them
# suggests looking at a cause rather than a symptom.
class AddOccurrencesToAlertConditions < ActiveRecord::Migration[8.1]
  def change
    add_column :alert_conditions, :occurrences, :integer, null: false, default: 0
  end
end

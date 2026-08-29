# frozen_string_literal: true

# Something that is wrong, and whether anybody has been told.
#
# The whole value of this class is what it refuses to do. A scan runs every
# quarter of an hour and hands it the same true statements over and over; this
# is what turns "the disk is full" being true four hundred times into one email
# when it starts and one when it stops.
class AlertCondition < ApplicationRecord
  CLEAR = "clear"
  PENDING = "pending"
  FIRING = "firing"

  validates :key, presence: true, uniqueness: true

  scope :firing, -> { where(state: FIRING) }
  scope :ordered, -> { order(:firing_since, :key) }

  # Records what a scan found for one condition, and answers what to say about
  # it, if anything.
  #
  # Returns `:opened`, `:closed`, or nil. nil is the common case and the point:
  # a condition that is still wrong, or still fine, is not news.
  def self.record(key, detail)
    condition = find_or_initialize_by(key: key)
    detail.nil? ? condition.clear! : condition.observe(detail)
  end

  # Seen wrong.
  #
  # Nothing is sent the first time. A module restarting during an upgrade, a
  # service reloading, a container that has just been replaced: all of those are
  # wrong for one scan and right for the next, and an alert for each of them is
  # how somebody learns to ignore the alerts.
  def observe(detail)
    case state
    when FIRING
      # Still wrong. The detail is kept current so the page shows today's
      # number, and nothing is sent, because nothing has changed.
      update!(detail: detail)
      nil
    when PENDING
      update!(state: FIRING, detail: detail, firing_since: Time.current,
              notified_at: Time.current, cleared_at: nil,
              occurrences: occurrences + 1)
      :opened
    else
      update!(state: PENDING, detail: detail, pending_since: Time.current, cleared_at: nil)
      nil
    end
  end

  # Seen fine.
  #
  # A condition that was only ever pending goes quiet without a word, because
  # nobody was ever told about it. One that was firing is worth closing: an
  # alert with no end is an alert somebody has to go and check.
  def clear!
    return nil if new_record? || state == CLEAR

    was_firing = state == FIRING
    update!(state: CLEAR, cleared_at: Time.current, pending_since: nil, firing_since: nil)

    was_firing ? :closed : nil
  end

  def for_how_long
    return nil if firing_since.nil?

    ((Time.current - firing_since) / 60).round
  end
end

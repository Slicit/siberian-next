# frozen_string_literal: true

# One queued build.
#
# The row is the queue, claimed with FOR UPDATE SKIP LOCKED. That is the same
# mechanism the mail queue uses, deliberately: a second builder can be added
# later without either of them learning about the other, and there is no second
# store that could disagree with this one about what is pending.
#
# Builds are slow. The retry budget is small and the backoff is long, because a
# build that failed because Gradle ran out of memory will fail the same way
# thirty seconds later, and trying again immediately only spends the shared
# builder that every domain is waiting for.
class Build < ApplicationRecord
  QUEUED = "queued"
  BUILDING = "building"
  SUCCEEDED = "succeeded"
  FAILED = "failed"
  DEAD = "dead"
  CANCELLED = "cancelled"

  STATES = [QUEUED, BUILDING, SUCCEEDED, FAILED, DEAD, CANCELLED].freeze
  TERMINAL = [SUCCEEDED, DEAD, CANCELLED].freeze

  ANDROID = "android"
  IOS = "ios"
  PLATFORMS = [ANDROID, IOS].freeze

  MAX_ATTEMPTS = 3
  BASE_BACKOFF = 5 * 60
  MAX_BACKOFF = 2 * 60 * 60

  # A build claimed by a worker that then died would sit in `building` forever.
  # Nothing else can tell the difference between that and a slow build, so the
  # only honest answer is a limit longer than any build should take.
  STALE_AFTER = 90 * 60

  belongs_to :mobile_app
  has_many :build_attempts, dependent: :destroy

  validates :domain, presence: true
  validates :platform, inclusion: { in: PLATFORMS }
  validates :state, inclusion: { in: STATES }

  scope :pending, -> { where(state: [QUEUED, FAILED]) }
  scope :terminal, -> { where(state: TERMINAL) }
  scope :unacknowledged, -> { terminal.where(acknowledged_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  STATES.each { |value| define_method("#{value}?") { state == value } }

  def terminal? = TERMINAL.include?(state)

  # Claims one build that is due, for one worker. SKIP LOCKED is the whole
  # trick: a second worker running this at the same moment steps over the
  # locked row rather than queueing behind it.
  def self.claim_next!
    transaction do
      build = pending
              .where(arel_table[:next_attempt_at].lteq(Time.current).or(arel_table[:next_attempt_at].eq(nil)))
              .order(:next_attempt_at, :id)
              .lock("FOR UPDATE SKIP LOCKED")
              .first

      next nil if build.nil?

      build.update!(state: BUILDING, claimed_at: Time.current, started_at: Time.current)
      build
    end
  end

  # A worker that died mid-build leaves a row nothing will ever finish. Putting
  # it back in the queue is safe because a build has no side effect until its
  # artifact is uploaded, and the artifact is named for the build.
  def self.release_stale!
    where(state: BUILDING)
      .where(arel_table[:claimed_at].lt(STALE_AFTER.seconds.ago))
      .find_each do |build|
        build.record_failure!(error: "the builder stopped answering", duration_ms: nil)
      end
  end

  def record_success!(artifact_path:, artifact_bytes:, duration_ms:, log: nil)
    transaction do
      build_attempts.create!(number: next_attempt_number, outcome: "succeeded",
                             duration_ms: duration_ms, attempted_at: Time.current)
      update!(state: SUCCEEDED, attempts: attempts + 1, finished_at: Time.current,
              artifact_path: artifact_path, artifact_bytes: artifact_bytes,
              last_error: nil, next_attempt_at: nil, log: log)
      mobile_app.increment!(:build_number)
    end
  end

  # `permanent` is the builder saying the configuration cannot produce an app:
  # a bundle identifier a store will not take, a capability whose key is wrong.
  # Retrying spends the shared builder to reach the same answer, so it does not
  # get to.
  def record_failure!(error:, permanent: false, duration_ms: nil, log: nil)
    transaction do
      build_attempts.create!(number: next_attempt_number, outcome: permanent ? "rejected" : "failed",
                             duration_ms: duration_ms, detail: error, attempted_at: Time.current)

      count = attempts + 1
      finished = permanent || count >= MAX_ATTEMPTS

      update!(
        state: finished ? DEAD : FAILED,
        attempts: count,
        last_error: error,
        log: log || self.log,
        finished_at: finished ? Time.current : nil,
        next_attempt_at: finished ? nil : Time.current + backoff_for(count)
      )
    end
  end

  def cancel!
    return false if terminal?

    update!(state: CANCELLED, finished_at: Time.current, next_attempt_at: nil)
  end

  def acknowledge!
    return false unless terminal?

    update!(acknowledged_at: Time.current)
  end

  private

  # Derived from the attempts already recorded, never from the retry budget: a
  # counter something else is allowed to reset is not a sequence. Reviving a
  # dead build resets the budget and keeps the history, and the two collide.
  def next_attempt_number
    (build_attempts.maximum(:number) || 0) + 1
  end

  def backoff_for(count)
    [BASE_BACKOFF * (5**(count - 1)), MAX_BACKOFF].min
  end
end

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
  # Not a platform anybody installs. The same project exported through React
  # Native for Web, so somebody can look at the app they configured without
  # waiting for a device: a preview of something else would be worth nothing.
  WEB = "web"
  PLATFORMS = [ANDROID, IOS, WEB].freeze

  MAX_ATTEMPTS = 3
  BASE_BACKOFF = 5 * 60
  MAX_BACKOFF = 2 * 60 * 60

  belongs_to :mobile_app
  has_many :build_attempts, dependent: :destroy

  validates :domain, presence: true
  validates :platform, inclusion: { in: PLATFORMS }
  validates :state, inclusion: { in: STATES }

  scope :pending, -> { where(state: [QUEUED, FAILED]) }
  scope :terminal, -> { where(state: TERMINAL) }
  scope :unacknowledged, -> { terminal.where(acknowledged_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  # Which worker takes a build.
  #
  # Derived from the platform rather than stored, because it is not a decision
  # anybody makes: an Expo export is about a minute and a Gradle build is twenty,
  # and one queue for both means the minute waits for the twenty. Somebody
  # pressing "Rebuild preview" behind an Android build waited a third of an hour
  # to look at a page, which is long enough that they stop asking.
  #
  # Two lanes, not two priorities. A priority queue with one worker still has
  # the Android build holding the worker: the preview does not jump it, it waits
  # for it to finish. Only a second worker fixes that.
  PREVIEW = "preview"
  NATIVE = "native"

  LANES = { WEB => PREVIEW, ANDROID => NATIVE, IOS => NATIVE }.freeze

  # An unknown platform is native, because native is the slow lane and putting
  # something unknown in the fast one is how the fast one stops being fast.
  def self.lane_for(platform) = LANES.fetch(platform.to_s, NATIVE)

  def lane = Build.lane_for(platform)

  scope :in_lanes, lambda { |lanes|
    wanted = Array(lanes).map(&:to_s)
    where(platform: LANES.select { |_platform, lane| wanted.include?(lane) }.keys)
  }

  # A build claimed by a worker that then died would sit in `building` forever.
  # Nothing else can tell the difference between that and a slow build, so the
  # only honest answer is a limit longer than any build of that kind should
  # take. Which is why it is per lane: ninety minutes is a sensible ceiling for
  # a Gradle build and an absurd one for an export that takes a minute, and
  # before the lanes existed there was only the one number to pick.
  #
  # A preview abandoned by a worker that was restarted underneath it used to
  # block its own queue for an hour and a half, which on a lane whose whole
  # purpose is being quick is the same as being broken.
  STALE_AFTER = { NATIVE => 90 * 60, PREVIEW => 10 * 60 }.freeze

  STATES.each { |value| define_method("#{value}?") { state == value } }

  def terminal? = TERMINAL.include?(state)

  # Waiting for the builder rather than finished with it. Queued and failed both
  # count, because a failed build is one due another attempt, and it matches the
  # `pending` scope on purpose: anything that reports a queue position has to
  # agree with what the queue is counting.
  def waiting? = [QUEUED, FAILED].include?(state)

  # Claims one build that is due, for one worker. SKIP LOCKED is the whole
  # trick: a second worker running this at the same moment steps over the
  # locked row rather than queueing behind it.
  # `lanes` is optional so that a worker which has not been told about lanes
  # keeps taking anything, which is what makes rolling this out safe: the old
  # container and the new one can both be running for a moment.
  def self.claim_next!(lanes: nil)
    transaction do
      waiting = lanes ? pending.in_lanes(lanes) : pending

      build = waiting
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
    STALE_AFTER.each do |lane, seconds|
      in_lanes(lane)
        .where(state: BUILDING)
        .where(arel_table[:claimed_at].lt(seconds.seconds.ago))
        .find_each do |build|
          build.record_failure!(error: "the builder stopped answering", duration_ms: nil)
        end
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
  # The part of a build log that says why it failed.
  #
  # A failed build recorded "gradle assembleRelease exited 1" as its error and
  # kept the log in a column nothing on the failure itself showed. Finding out
  # that the real cause was a splash image AAPT could not compile took reading
  # the log out of the database by hand.
  #
  # Gradle puts the useful part under "What went wrong", so that is what is
  # looked for. When it is not there, the tail is a better guess than nothing:
  # a build tool that has just failed says why near the end.
  WHY_LINES = 12

  def self.why_it_failed(log, fallback)
    text = log.to_s
    return fallback if text.strip.empty?

    marker = text.index("What went wrong")
    excerpt = if marker
                text[marker, 600]
              else
                text.lines.last(WHY_LINES).join
              end

    excerpt = excerpt.to_s.strip
    return fallback if excerpt.empty?

    "#{fallback}: #{excerpt}"
  end

  def record_failure!(error:, permanent: false, duration_ms: nil, log: nil)
    # The attempt carries the reason rather than the summary, because the
    # attempt is what a person reads when they ask why a build failed.
    detail = self.class.why_it_failed(log, error)

    transaction do
      build_attempts.create!(number: next_attempt_number, outcome: permanent ? "rejected" : "failed",
                             duration_ms: duration_ms, detail: detail, attempted_at: Time.current)

      count = attempts + 1
      finished = permanent || count >= MAX_ATTEMPTS

      update!(
        state: finished ? DEAD : FAILED,
        attempts: count,
        last_error: detail,
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

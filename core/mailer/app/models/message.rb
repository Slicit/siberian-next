# frozen_string_literal: true

# One queued message.
#
# The row is the queue. Claiming is `FOR UPDATE SKIP LOCKED`, which lets several
# workers take work without coordinating and without a second store that could
# disagree with this one.
class Message < ApplicationRecord
  QUEUED = "queued"
  SENDING = "sending"
  SENT = "sent"
  FAILED = "failed"
  DEAD = "dead"
  CANCELLED = "cancelled"

  STATES = [QUEUED, SENDING, SENT, FAILED, DEAD, CANCELLED].freeze

  # Nothing more will happen on its own. These are the outcomes a module has to
  # acknowledge.
  TERMINAL = [SENT, DEAD, CANCELLED].freeze

  # Roughly a minute, then five, then twenty five, capped. Jittered, because a
  # transport that has just come back should not meet the whole backlog in the
  # same second.
  BASE_BACKOFF = 60
  MAX_BACKOFF = 6 * 60 * 60

  belongs_to :module_registration
  has_many :delivery_attempts, dependent: :destroy

  validates :to, :subject, :domain, presence: true
  validates :state, inclusion: { in: STATES }
  validate :has_a_body

  scope :terminal, -> { where(state: TERMINAL) }
  scope :unacknowledged, -> { terminal.where(acknowledged_at: nil) }
  scope :pending, -> { where(state: [QUEUED, FAILED]) }
  scope :recent, -> { order(created_at: :desc) }

  STATES.each { |value| define_method("#{value}?") { state == value } }

  def terminal? = TERMINAL.include?(state)
  def acknowledged? = acknowledged_at.present?

  # Claims one message that is due, for one worker.
  #
  # SKIP LOCKED is the whole trick: a second worker running this at the same
  # moment steps over the locked row rather than waiting behind it, so workers
  # scale without talking to each other.
  def self.claim_next!
    transaction do
      message = pending
                .where(arel_table[:next_attempt_at].lteq(Time.current).or(arel_table[:next_attempt_at].eq(nil)))
                .order(:next_attempt_at, :id)
                .lock("FOR UPDATE SKIP LOCKED")
                .first

      next nil if message.nil?

      message.update!(state: SENDING)
      message
    end
  end

  def record_success!(transport:, duration_ms:, detail: nil)
    transaction do
      delivery_attempts.create!(
        number: next_attempt_number, outcome: "delivered", transport: transport,
        duration_ms: duration_ms, detail: detail, attempted_at: Time.current
      )
      update!(state: SENT, attempts: attempts + 1, sent_at: Time.current,
              transport: transport, last_error: nil, next_attempt_at: nil)
    end
  end

  # A rejection is the transport saying no: a bad address, a refused sender.
  # Retrying produces the same answer, so it does not get one and the message
  # goes straight to dead rather than burning five more attempts to find out.
  def record_failure!(transport:, error:, permanent: false, duration_ms: nil)
    transaction do
      delivery_attempts.create!(
        number: next_attempt_number, outcome: permanent ? "rejected" : "error",
        transport: transport, duration_ms: duration_ms,
        detail: error.to_s[0, 2000], attempted_at: Time.current
      )

      count = attempts + 1
      exhausted = permanent || count >= max_attempts

      update!(
        state: exhausted ? DEAD : FAILED,
        attempts: count,
        transport: transport,
        last_error: error.to_s[0, 2000],
        next_attempt_at: exhausted ? nil : Time.current + backoff_for(count)
      )
    end
  end

  # Puts a dead message back in the queue, with its attempt count reset.
  #
  # The attempt history is kept: the point of retrying by hand is usually that
  # something outside changed, and the earlier failures are the evidence for
  # what.
  def revive!(max_attempts: nil)
    update!(
      state: QUEUED,
      attempts: 0,
      max_attempts: max_attempts || self.max_attempts,
      next_attempt_at: Time.current,
      last_error: nil,
      acknowledged_at: nil
    )
  end

  def cancel!
    return false if terminal?

    update!(state: CANCELLED, next_attempt_at: nil)
  end

  def acknowledge!
    return false unless terminal?

    update!(acknowledged_at: Time.current)
  end

  # Attempt numbers are monotonic for the life of the message, and deliberately
  # not derived from `attempts`. Reviving a dead message resets the retry budget
  # but keeps the history, so a counter-derived number would collide with an
  # attempt that already exists.
  def next_attempt_number
    delivery_attempts.maximum(:number).to_i + 1
  end

  # Exponential with jitter, capped. The jitter is up to a quarter of the
  # interval, which is enough to spread a backlog without making the wait feel
  # arbitrary.
  def backoff_for(attempt)
    base = [BASE_BACKOFF * (5**(attempt - 1)), MAX_BACKOFF].min
    base + rand((base / 4.0).ceil)
  end

  def to_payload
    {
      id: id,
      to: to, cc: cc, bcc: bcc, from: from, reply_to: reply_to,
      subject: subject,
      text_body: text_body, html_body: html_body,
      headers: headers || {},
      domain: domain,
      module_name: module_registration.module_name
    }
  end

  def summary
    {
      id: id,
      state: state,
      to: to,
      subject: subject,
      attempts: attempts,
      max_attempts: max_attempts,
      next_attempt_at: next_attempt_at,
      sent_at: sent_at,
      transport: transport,
      last_error: last_error,
      acknowledged: acknowledged?,
      idempotency_key: idempotency_key,
      created_at: created_at
    }
  end

  def detail
    summary.merge(
      attempts_log: delivery_attempts.ordered.map do |attempt|
        {
          number: attempt.number, outcome: attempt.outcome, transport: attempt.transport,
          duration_ms: attempt.duration_ms, detail: attempt.detail, attempted_at: attempt.attempted_at
        }
      end
    )
  end

  private

  def has_a_body
    return if text_body.present? || html_body.present?

    errors.add(:base, "a message needs a text_body or an html_body")
  end
end

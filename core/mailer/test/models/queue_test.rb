# frozen_string_literal: true

require "test_helper"

class QueueTest < ActiveSupport::TestCase
  setup do
    @registration, @token = ModuleRegistration.register!(module_name: "notes", module_uuid: "abc")
  end

  def enqueue(**overrides)
    @registration.messages.create!({
      domain: "example.test", to: "someone@example.test",
      subject: "Hello", text_body: "Body", next_attempt_at: Time.current
    }.merge(overrides))
  end

  # Queueing --------------------------------------------------------------

  test "a message needs a body of some kind" do
    message = @registration.messages.build(domain: "example.test", to: "a@example.test", subject: "x")

    refute message.valid?
    assert_includes message.errors.full_messages.join, "text_body or an html_body"
  end

  test "an html body alone is enough" do
    assert enqueue(text_body: nil, html_body: "<p>hi</p>").valid?
  end

  test "one idempotency key is one message" do
    enqueue(idempotency_key: "abc")

    assert_raises(ActiveRecord::RecordNotUnique) do
      @registration.messages.create!(domain: "example.test", to: "b@example.test",
                                     subject: "y", text_body: "z", idempotency_key: "abc")
    end
  end

  test "two modules can use the same idempotency key" do
    other, = ModuleRegistration.register!(module_name: "tasks", module_uuid: "def")
    enqueue(idempotency_key: "shared")

    assert other.messages.create!(domain: "example.test", to: "b@example.test", subject: "y",
                                  text_body: "z", idempotency_key: "shared").persisted?
  end

  # Claiming --------------------------------------------------------------

  test "claiming takes the oldest due message and marks it sending" do
    first = enqueue(next_attempt_at: 1.hour.ago)
    enqueue(next_attempt_at: 1.minute.ago)

    claimed = Message.claim_next!

    assert_equal first.id, claimed.id
    assert claimed.sending?
  end

  test "a message scheduled for later is not claimed" do
    enqueue(next_attempt_at: 1.hour.from_now)

    assert_nil Message.claim_next!
  end

  test "a message already sending is not claimed twice" do
    enqueue
    Message.claim_next!

    assert_nil Message.claim_next!, "claiming has to be exclusive or a message sends twice"
  end

  test "a failed message becomes claimable again once its backoff has passed" do
    message = enqueue
    message.update!(state: Message::FAILED, next_attempt_at: 1.minute.ago)

    assert_equal message.id, Message.claim_next!&.id
  end

  # Outcomes --------------------------------------------------------------

  test "success records an attempt and stops the message moving" do
    message = enqueue
    message.record_success!(transport: "core-recorder", duration_ms: 12)

    assert message.sent?
    assert_equal 1, message.attempts
    assert message.sent_at.present?
    assert_nil message.next_attempt_at
    assert_equal "delivered", message.delivery_attempts.last.outcome
  end

  test "a transient failure schedules a retry" do
    message = enqueue
    message.record_failure!(transport: "core-recorder", error: "connection refused")

    assert message.failed?
    assert_equal 1, message.attempts
    assert message.next_attempt_at > Time.current
  end

  test "a permanent failure skips straight to dead" do
    message = enqueue
    message.record_failure!(transport: "relay", error: "HTTP 400: bad address", permanent: true)

    assert message.dead?
    assert_equal 1, message.attempts, "a rejection will say the same thing five more times"
    assert_nil message.next_attempt_at
  end

  test "a message dies once its attempts are spent" do
    message = enqueue(max_attempts: 2)

    message.record_failure!(transport: "t", error: "one")
    assert message.failed?

    message.record_failure!(transport: "t", error: "two")
    assert message.dead?
    assert_equal 2, message.delivery_attempts.count
  end

  test "backoff grows and stays inside the cap" do
    message = enqueue

    first = message.backoff_for(1)
    second = message.backoff_for(2)
    far = message.backoff_for(12)

    assert_operator second, :>, first
    assert_operator far, :<=, Message::MAX_BACKOFF * 1.25, "the cap has to hold, jitter included"
  end

  # Acknowledgement -------------------------------------------------------

  test "a terminal outcome is reported until it is acknowledged" do
    message = enqueue
    message.record_success!(transport: "t", duration_ms: 1)

    assert_includes @registration.messages.unacknowledged, message

    message.acknowledge!
    refute_includes @registration.messages.reload.unacknowledged, message
  end

  test "there is nothing to acknowledge before a message finishes" do
    message = enqueue

    refute message.acknowledge!, "a queued message has no outcome to acknowledge"
    assert_nil message.reload.acknowledged_at
  end

  test "reviving a dead message clears its acknowledgement" do
    message = enqueue(max_attempts: 1)
    message.record_failure!(transport: "t", error: "nope")
    message.acknowledge!

    message.revive!

    assert message.queued?
    assert_equal 0, message.attempts
    assert_nil message.acknowledged_at, "an outcome that has been undone has not been seen"
    assert_equal 1, message.delivery_attempts.count, "the history is the evidence, so it stays"
  end

  test "attempt numbers keep going up across a revive" do
    message = enqueue(max_attempts: 1)
    message.record_failure!(transport: "t", error: "first")
    message.revive!

    # The retry budget resets and the history does not, so a number derived from
    # the counter would collide with an attempt that already exists.
    message.record_failure!(transport: "t", error: "second")

    assert_equal [1, 2], message.delivery_attempts.ordered.pluck(:number)
    assert_equal 1, message.attempts, "the budget still counts from the revive"
  end

  # Cancelling ------------------------------------------------------------

  test "a queued message can be cancelled" do
    message = enqueue

    assert message.cancel!
    assert message.cancelled?
  end

  test "a sent message cannot be cancelled" do
    message = enqueue
    message.record_success!(transport: "t", duration_ms: 1)

    refute message.cancel!
    assert message.sent?
  end

  # Limits ----------------------------------------------------------------

  test "a daily limit counts only what was sent today" do
    limited, = ModuleRegistration.register!(module_name: "limited", module_uuid: "l", daily_limit: 1)
    message = limited.messages.create!(domain: "example.test", to: "a@example.test",
                                       subject: "x", text_body: "y")
    refute limited.over_daily_limit?

    message.record_success!(transport: "t", duration_ms: 1)
    assert limited.reload.over_daily_limit?
  end

  test "a module with no limit is never over it" do
    refute @registration.over_daily_limit?
  end
end

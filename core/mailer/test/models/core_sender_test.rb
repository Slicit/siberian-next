# frozen_string_literal: true

require "test_helper"

# A message is sent by exactly one of a module or a core service. The interesting
# cases are the ones the database refuses, because a message with no sender has
# nothing to be isolated by and one with two has no answer to "whose is this".
class CoreSenderTest < ActiveSupport::TestCase
  setup do
    @module_registration, = ModuleRegistration.register!(module_name: "demo-tasks",
                                                         module_uuid: SecureRandom.uuid)
  end

  def core_message(**overrides)
    Message.new({
      core_sender: "core-auth", domain: "one.test",
      to: "rider@example.test", subject: "Reset your password",
      text_body: "a link", state: Message::QUEUED
    }.merge(overrides))
  end

  test "a core service can send" do
    message = core_message

    assert message.save
    assert_equal "core-auth", message.sender_name
    assert message.from_core?
  end

  test "a module can still send" do
    message = core_message(core_sender: nil, module_registration: @module_registration)

    assert message.save
    assert_equal "demo-tasks", message.sender_name
    refute message.from_core?
  end

  test "a message with no sender is refused" do
    refute core_message(core_sender: nil).valid?
  end

  test "a message with two senders is refused" do
    refute core_message(module_registration: @module_registration).valid?,
           "a message that belongs to both has no answer to whose it is"
  end

  test "the database refuses a message with no sender even without the model" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Message.connection.execute(<<~SQL.squish)
        INSERT INTO messages (domain, "to", subject, text_body, state, created_at, updated_at)
        VALUES ('one.test', 'a@b.test', 's', 'b', 'queued', now(), now())
      SQL
    end
  end

  # A transport is handed the sender's name and does not learn which kind it
  # was, because no transport acts on the difference.
  test "the payload names the sender whichever kind it is" do
    assert_equal "core-auth", core_message.to_payload[:module_name]

    from_module = core_message(core_sender: nil, module_registration: @module_registration)
    assert_equal "demo-tasks", from_module.to_payload[:module_name]
  end

  # The index refuses it, not a validation, which is the same way a module's
  # idempotency key is enforced. The controller looks the key up and answers
  # with the existing message before it ever tries to insert, so this raising
  # is the floor under that rather than the path a caller takes.
  test "the same idempotency key cannot be used twice by one core sender" do
    assert core_message(idempotency_key: "reset-1").save

    assert_raises(ActiveRecord::RecordNotUnique) do
      core_message(idempotency_key: "reset-1").save
    end
  end

  test "two core senders may each use the same key" do
    assert core_message(idempotency_key: "reset-1").save
    assert core_message(core_sender: "core-orchestrator", idempotency_key: "reset-1").save,
           "one sender's keys are not another's namespace"
  end
end

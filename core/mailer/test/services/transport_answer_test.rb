# frozen_string_literal: true

require "test_helper"

# What the core does with a transport's answer.
#
# A transport can accept a message and not send it. One in the catalogue does
# exactly that, honestly: it answers 2xx with "sent": false, because a transport
# that discards mail and reports success is a bug in a nicer disguise.
#
# That honesty used to be thrown away here. The answer was read as HTTP 200 and
# nothing else, so the message was recorded delivered with nothing anywhere
# saying it had gone nowhere, which put the bug straight back.
class TransportAnswerTest < ActiveSupport::TestCase
  # The private method under test, reached the way the class reaches it. Going
  # through deliver would need a socket, and what is being tested is the reading
  # of an answer rather than the getting of one.
  def read(body, code = 200)
    Transport::Remote.new(name: "example", url: "http://example.test/mail")
                     .send(:delivered, code, body)
  end

  test "a transport that says it sent the message is believed" do
    result = read('{"accepted":true,"sent":true}')

    assert_equal "delivered", result.outcome
    assert_equal "HTTP 200", result.detail
  end

  test "a transport that says it did not is still delivered, and says so" do
    result = read('{"accepted":true,"recorded":true,"sent":false}')

    # Delivered, deliberately. The transport did its job and asking again would
    # only produce another copy of the same non-delivery.
    assert_equal "delivered", result.outcome
    assert_match "not sent onward", result.detail
  end

  # Most transports will never mention it, and silence is not an admission.
  test "a transport that says nothing about it is believed too" do
    result = read('{"accepted":true}')

    assert_equal "HTTP 200", result.detail
  end

  test "an answer that is not JSON at all does not take the delivery down" do
    result = read("Accepted for delivery")

    assert_equal "delivered", result.outcome
    assert_equal "HTTP 200", result.detail
  end

  test "an empty answer is fine, because 2xx with no body is a normal answer" do
    result = read("")

    assert_equal "delivered", result.outcome
  end
end

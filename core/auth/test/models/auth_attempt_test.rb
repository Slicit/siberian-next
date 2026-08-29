# frozen_string_literal: true

require "test_helper"

# A throttle that can be walked around is a throttle that only inconveniences
# the people it was not aimed at. These are the ways around it.
class AuthAttemptTest < ActiveSupport::TestCase
  def record(times, kind: AuthAttempt::SIGN_IN, identifier: "rider@example.test", ip: "10.0.0.1")
    times.times do
      AuthAttempt.record!(kind: kind, identifier: identifier, domain: "one.test", ip_address: ip)
    end
  end

  test "an address is refused after its limit, from any source" do
    record(10, ip: "10.0.0.1")

    assert AuthAttempt.exhausted?(kind: AuthAttempt::SIGN_IN,
                                 identifier: "rider@example.test", ip_address: "10.9.9.9"),
           "counting only by source lets one attacker spread the same guess across a botnet"
  end

  test "a source is refused after its limit, against any address" do
    # Thirty from one source, spread thin enough that no single address is
    # anywhere near its own limit of ten.
    5.times do |i|
      record(6, identifier: "person#{i}@example.test", ip: "10.0.0.1")
    end

    assert AuthAttempt.exhausted?(kind: AuthAttempt::SIGN_IN,
                                 identifier: "untouched@example.test", ip_address: "10.0.0.1"),
           "counting only by address lets one source walk a list of addresses"
  end

  test "under the limit is not refused" do
    record(9)

    refute AuthAttempt.exhausted?(kind: AuthAttempt::SIGN_IN,
                                 identifier: "rider@example.test", ip_address: "10.0.0.1")
  end

  test "case and space do not buy another allowance" do
    record(10, identifier: "rider@example.test")

    assert AuthAttempt.exhausted?(kind: AuthAttempt::SIGN_IN, identifier: "  Rider@Example.test ")
  end

  test "resetting is limited harder than signing in" do
    record(3, kind: AuthAttempt::RESET)

    assert AuthAttempt.exhausted?(kind: AuthAttempt::RESET, identifier: "rider@example.test"),
           "each reset emails somebody who may not have asked, so the limit is about them"
    refute AuthAttempt.exhausted?(kind: AuthAttempt::SIGN_IN, identifier: "rider@example.test"),
           "the two are counted apart, or asking for a reset would lock somebody out of signing in"
  end

  test "attempts outside the window do not count" do
    record(10)
    AuthAttempt.update_all(created_at: 2.hours.ago)

    refute AuthAttempt.exhausted?(kind: AuthAttempt::SIGN_IN, identifier: "rider@example.test"),
           "a limit that never forgets is a permanent lockout with extra steps"
  end

  test "succeeding clears the count" do
    record(10)
    AuthAttempt.forget!(kind: AuthAttempt::SIGN_IN, identifier: "rider@example.test")

    refute AuthAttempt.exhausted?(kind: AuthAttempt::SIGN_IN, identifier: "rider@example.test"),
           "mistyping three times and then getting it right should not leave somebody nearly locked out"
  end

  test "clearing one kind leaves the other alone" do
    record(3, kind: AuthAttempt::RESET)
    AuthAttempt.forget!(kind: AuthAttempt::SIGN_IN, identifier: "rider@example.test")

    assert AuthAttempt.exhausted?(kind: AuthAttempt::RESET, identifier: "rider@example.test"),
           "signing in successfully must not be a way to top up the reset allowance"
  end

  test "the sweep keeps recent attempts and drops old ones" do
    record(2)
    AuthAttempt.update_all(created_at: 3.days.ago)
    record(2)

    AuthAttempt.sweep!

    assert_equal 2, AuthAttempt.count
  end
end

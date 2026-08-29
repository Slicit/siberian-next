# frozen_string_literal: true

require "test_helper"

# The anti-noise rules, which are the whole value of this class.
#
# A scan runs every quarter of an hour and hands it the same true statements
# over and over. Every test here is about something it refuses to say.
class AlertConditionTest < ActiveSupport::TestCase
  test "nothing is said the first time something looks wrong" do
    assert_nil AlertCondition.record("disk.low", "200 MB free"),
               "a service restarting during a deploy is wrong for one scan and right for the next"
    assert_equal AlertCondition::PENDING, AlertCondition.find_by(key: "disk.low").state
  end

  test "it fires once it has held across two scans" do
    AlertCondition.record("disk.low", "200 MB free")

    assert_equal :opened, AlertCondition.record("disk.low", "190 MB free")
    assert_equal AlertCondition::FIRING, AlertCondition.find_by(key: "disk.low").state
  end

  # The rule that decides whether anybody keeps reading these.
  test "a condition that is still true is never mentioned again" do
    AlertCondition.record("disk.low", "200 MB free")
    AlertCondition.record("disk.low", "190 MB free")

    20.times { |i| assert_nil AlertCondition.record("disk.low", "#{180 - i} MB free") }
  end

  test "but the page still shows today's number" do
    AlertCondition.record("disk.low", "200 MB free")
    AlertCondition.record("disk.low", "190 MB free")
    AlertCondition.record("disk.low", "120 MB free")

    assert_equal "120 MB free", AlertCondition.find_by(key: "disk.low").detail
  end

  test "clearing is said once, because an alert with no end has to be chased" do
    AlertCondition.record("disk.low", "200 MB free")
    AlertCondition.record("disk.low", "190 MB free")

    assert_equal :closed, AlertCondition.record("disk.low", nil)
    assert_nil AlertCondition.record("disk.low", nil)
  end

  # The counterpart to holding twice: something that flickered was never
  # announced, so its recovery must not be either.
  test "something that never fired is not announced as resolved" do
    AlertCondition.record("module.notes", "restarting")

    assert_nil AlertCondition.record("module.notes", nil),
               "nobody was told it broke, so nobody needs telling it is better"
  end

  test "something fine is not recorded at all" do
    assert_nil AlertCondition.record("disk.low", nil)
    assert_equal 0, AlertCondition.count,
                 "a table with a row per healthy thing is a table nobody reads"
  end

  test "a condition that comes back fires again" do
    AlertCondition.record("disk.low", "200 MB free")
    AlertCondition.record("disk.low", "190 MB free")
    AlertCondition.record("disk.low", nil)

    assert_nil AlertCondition.record("disk.low", "again")
    assert_equal :opened, AlertCondition.record("disk.low", "still")
  end

  test "how long it has been true is answerable" do
    AlertCondition.record("disk.low", "200 MB free")
    AlertCondition.record("disk.low", "190 MB free")

    condition = AlertCondition.find_by(key: "disk.low")
    condition.update!(firing_since: 40.minutes.ago)

    assert_equal 40, condition.for_how_long
  end

  test "two different conditions do not interfere" do
    AlertCondition.record("disk.low", "200 MB free")
    AlertCondition.record("sweep.red", "two checks failing")
    AlertCondition.record("disk.low", "190 MB free")

    assert_equal AlertCondition::FIRING, AlertCondition.find_by(key: "disk.low").state
    assert_equal AlertCondition::PENDING, AlertCondition.find_by(key: "sweep.red").state
  end
end

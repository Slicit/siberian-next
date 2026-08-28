# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Reading the result of the unattended sweep.
#
# The cases worth testing are the ones where the honest answer is "I do not
# know": no file, an unreadable file, and a result old enough that passing means
# nothing. A card that draws green in any of those reproduces the failure this
# feature exists to remove.
class NightlyChecksTest < ActiveSupport::TestCase
  def with_results(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "latest.json")
      File.write(path, contents) unless contents.nil?
      yield NightlyChecks.new(path: path)
    end
  end

  def result(ran_at:, checks:, duration: 42)
    JSON.generate(
      "ran_at" => ran_at.iso8601,
      "duration_seconds" => duration,
      "total" => checks.length,
      "failures" => checks.count { |c| c["status"] != "ok" },
      "checks" => checks
    )
  end

  def passing = [{ "name" => "smoke-auth", "status" => "ok", "seconds" => 3, "detail" => "" }]

  test "a box where the sweep has never run reports nothing rather than failure" do
    with_results(nil) do |checks|
      refute checks.available?
      refute checks.ok?
      assert_empty checks.checks
    end
  end

  test "a recent clean sweep is green" do
    with_results(result(ran_at: 2.hours.ago, checks: passing)) do |checks|
      assert checks.available?
      assert checks.ok?
      assert_equal 1, checks.passed
      assert_empty checks.failures
    end
  end

  test "a failing check is reported with what it said" do
    failing = passing + [{
      "name" => "smoke-cms", "status" => "failed", "seconds" => 9,
      "detail" => "step 4 answered 500"
    }]

    with_results(result(ran_at: 1.hour.ago, checks: failing)) do |checks|
      refute checks.ok?
      assert_equal 1, checks.passed
      assert_equal ["smoke-cms"], checks.failures.map(&:name)
      assert_match(/answered 500/, checks.failures.first.detail)
    end
  end

  # The point of the staleness rule. A sweep that stopped running two weeks ago
  # and passed when it did is not evidence that anything works now.
  test "an old clean sweep is not green" do
    with_results(result(ran_at: 5.days.ago, checks: passing)) do |checks|
      assert checks.available?
      assert checks.stale?
      refute checks.ok?, "a stale pass must not be drawn as a pass"
    end
  end

  test "a result with no timestamp is treated as stale" do
    with_results(JSON.generate("checks" => passing)) do |checks|
      assert checks.stale?
      refute checks.ok?
    end
  end

  test "an unparseable file is not mistaken for a passing one" do
    with_results("{ this is not json") do |checks|
      refute checks.available?
      refute checks.ok?
    end
  end

  test "a file that is not an object is not mistaken for a result" do
    with_results(JSON.generate([1, 2, 3])) do |checks|
      refute checks.available?
      refute checks.ok?
    end
  end
end

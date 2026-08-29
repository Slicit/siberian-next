# frozen_string_literal: true

require "test_helper"

# Which queue a build waits in.
#
# One queue for everything meant a web export, which takes about a minute,
# waiting behind a Gradle build, which takes twenty. Somebody pressing "Rebuild
# preview" behind an Android build waited a third of an hour to look at a page.
class BuildLaneTest < ActiveSupport::TestCase
  setup do
    Build.delete_all
    MobileApp.delete_all
    @app = MobileApp.create!(domain: "lanes.test", name: "Lanes",
                             bundle_identifier: "test.lanes", version: "1.0.0")
  end

  def queued(platform) = @app.builds.create!(domain: "lanes.test", platform: platform)

  test "a web build is a preview and the device builds are native" do
    assert_equal Build::PREVIEW, Build.lane_for("web")
    assert_equal Build::NATIVE, Build.lane_for("android")
    assert_equal Build::NATIVE, Build.lane_for("ios")
  end

  # Native is the slow lane. Something unknown landing in the fast one is how
  # the fast one stops being fast.
  test "a platform nobody has heard of is native rather than a preview" do
    assert_equal Build::NATIVE, Build.lane_for("blackberry")
  end

  # The property the whole change exists for.
  test "a preview does not wait behind an Android build" do
    android = queued(Build::ANDROID)
    web = queued(Build::WEB)

    assert_equal web.id, Build.claim_next!(lanes: [Build::PREVIEW]).id
    assert_equal Build::QUEUED, android.reload.state
  end

  test "and the native worker does not take the preview" do
    queued(Build::WEB)
    android = queued(Build::ANDROID)

    assert_equal android.id, Build.claim_next!(lanes: [Build::NATIVE]).id
  end

  test "a native worker with nothing to do takes nothing rather than the other lane" do
    queued(Build::WEB)

    assert_nil Build.claim_next!(lanes: [Build::NATIVE])
  end

  # What makes the rollout safe: the container running before this existed asks
  # for no lane, and must keep working rather than idling next to a full queue.
  test "a worker that names no lane still takes anything" do
    queued(Build::WEB)

    assert_not_nil Build.claim_next!
  end

  test "a worker asking for a lane nobody has heard of gets nothing" do
    queued(Build::WEB)
    queued(Build::ANDROID)

    assert_nil Build.claim_next!(lanes: ["express"])
  end

  # Two workers claiming at the same moment is the case SKIP LOCKED is for, and
  # with lanes they are usually not even looking at the same rows.
  test "two workers in different lanes each get their own" do
    queued(Build::ANDROID)
    queued(Build::WEB)

    native = Build.claim_next!(lanes: [Build::NATIVE])
    preview = Build.claim_next!(lanes: [Build::PREVIEW])

    assert_not_equal native.id, preview.id
    assert_equal Build::NATIVE, native.lane
    assert_equal Build::PREVIEW, preview.lane
  end


  # The belt to the lane filter's braces. A worker handed a build it should not
  # have puts it back rather than doing it, and this is the endpoint that lets
  # it: without one, a misrouted build sits in BUILDING until the stale timeout.
  test "a build put back is queued again with its attempts untouched" do
    build = queued(Build::ANDROID)
    Build.claim_next!

    assert_equal Build::BUILDING, build.reload.state

    build.update!(state: Build::QUEUED, claimed_at: nil, started_at: nil)

    assert_equal Build::QUEUED, build.reload.state
    assert_equal 0, build.attempts
    assert_nil build.claimed_at
  end

  # Putting it back means the other worker can have it, which is the whole
  # point: the stale timeout is measured in minutes and a preview is measured in
  # one.
  test "and the worker that does take that lane can then claim it" do
    build = queued(Build::WEB)
    Build.claim_next!(lanes: [Build::NATIVE])

    assert_equal Build::QUEUED, build.reload.state, "the native lane should not have taken it at all"
    assert_equal build.id, Build.claim_next!(lanes: [Build::PREVIEW]).id
  end
  test "order within a lane is still first in, first out" do
    first = queued(Build::ANDROID)
    queued(Build::IOS)

    assert_equal first.id, Build.claim_next!(lanes: [Build::NATIVE]).id
  end
end

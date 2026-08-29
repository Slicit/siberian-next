# frozen_string_literal: true

require "test_helper"

# Which build artifacts survive, and which are let go.
#
# The first test in this service, written because retention is the kind of logic
# where being wrong is expensive in one direction: keeping too much wastes a
# disk, and keeping too little destroys the binary somebody was about to
# install. The tests are mostly about the second.
class ArtifactRetentionTest < ActiveSupport::TestCase
  # Records what it was asked to delete and never touches a network.
  class FakeStorage
    attr_reader :removed

    def initialize(failing: []) = (@removed = []; @failing = failing)

    def remove(domain:, path:)
      raise StandardError, "storage said no" if @failing.include?(path)

      @removed << path
      true
    end
  end

  def app(bundle: "test.siberian")
    MobileApp.create!(domain: "example.test", bundle_identifier: bundle, name: "Test")
  end

  def build_for(mobile_app, platform: "android", artifact: true, bytes: 60)
    Build.create!(
      mobile_app: mobile_app, domain: "example.test", platform: platform,
      state: Build::SUCCEEDED,
      artifact_path: artifact ? "files/apps/#{platform}/#{SecureRandom.hex(4)}.apk" : nil,
      artifact_bytes: artifact ? bytes * 1_048_576 : nil
    )
  end

  test "the newest artifact for an app and platform is kept" do
    subject = app
    old = build_for(subject)
    newest = build_for(subject)
    storage = FakeStorage.new

    ArtifactRetention.new(storage: storage).call

    assert_equal [old.artifact_path], storage.removed
    assert_nil old.reload.artifact_path, "a removed artifact must stop being offered"
    assert_equal newest.artifact_path, newest.reload.artifact_path
  end

  # Each platform is a separate answer to "can I install this now", so keeping
  # one artifact overall would delete the only iOS build to keep an Android one.
  test "each platform keeps its own newest" do
    subject = app
    android = build_for(subject, platform: "android")
    ios = build_for(subject, platform: "ios")
    storage = FakeStorage.new

    ArtifactRetention.new(storage: storage).call

    assert_empty storage.removed
    assert_equal android.artifact_path, android.reload.artifact_path
    assert_equal ios.artifact_path, ios.reload.artifact_path
  end

  test "each app keeps its own newest" do
    first = build_for(app(bundle: "one.siberian"))
    second = build_for(app(bundle: "two.siberian"))
    storage = FakeStorage.new

    ArtifactRetention.new(storage: storage).call

    assert_empty storage.removed, "one app's builds must not expire another's"
    assert first.reload.artifact_path
    assert second.reload.artifact_path
  end

  test "keeping more than one is possible" do
    subject = app
    oldest = build_for(subject)
    build_for(subject)
    build_for(subject)
    storage = FakeStorage.new

    ArtifactRetention.new(keep: 2, storage: storage).call

    assert_equal [oldest.artifact_path], storage.removed
  end

  # Keeping zero would delete the only installable build, so the floor is one
  # however the setting is written.
  test "keeping zero is treated as keeping one" do
    subject = app
    build_for(subject)
    newest = build_for(subject)
    storage = FakeStorage.new

    ArtifactRetention.new(keep: 0, storage: storage).call

    assert_equal newest.artifact_path, newest.reload.artifact_path
  end

  test "a build whose artifact is already gone is left alone" do
    subject = app
    gone = build_for(subject, artifact: false)
    build_for(subject)
    storage = FakeStorage.new

    ArtifactRetention.new(storage: storage).call

    assert_nil gone.reload.artifact_path
    refute_includes storage.removed, nil
  end

  # The record must not say the binary is gone while it is still there: that is
  # the one state where the space can never be reclaimed, because nothing knows
  # to look for it.
  test "a failed delete leaves the path in place to be retried" do
    subject = app
    old = build_for(subject)
    build_for(subject)
    storage = FakeStorage.new(failing: [old.artifact_path])

    result = ArtifactRetention.new(storage: storage).call

    refute result.ok?
    assert old.reload.artifact_path, "the path is how the next run finds it again"
  end

  test "a dry run removes nothing and still reports the size" do
    subject = app
    old = build_for(subject, bytes: 60)
    build_for(subject)
    storage = FakeStorage.new

    result = ArtifactRetention.new(storage: storage).call(dry_run: true)

    assert_empty storage.removed
    assert old.reload.artifact_path
    assert_equal 1, result.removed
    assert_equal 60.0, result.megabytes
  end

  test "the log and the outcome survive the binary" do
    subject = app
    old = build_for(subject)
    old.update!(log: "gradle said things", state: Build::SUCCEEDED)
    build_for(subject)

    ArtifactRetention.new(storage: FakeStorage.new).call

    assert_equal "gradle said things", old.reload.log
    assert_equal Build::SUCCEEDED, old.state
  end
end

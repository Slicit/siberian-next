# frozen_string_literal: true

require "test_helper"

# What a person reads when they ask why a build failed.
#
# It used to say "gradle assembleRelease exited 1", which is the exit code
# wearing a sentence. Finding out that the real cause was a splash image AAPT
# could not compile meant reading the log column out of the database by hand.
class BuildFailureTest < ActiveSupport::TestCase
  GRADLE = <<~LOG
    > Task :app:mergeReleaseResources FAILED

    FAILURE: Build failed with an exception.

    * What went wrong:
    Execution failed for task ':app:mergeReleaseResources'.
    > Android resource compilation failed
      ERROR: splashscreen_image.png: AAPT: error: file failed to compile.

    * Try:
    > Run with --stacktrace option to get the stack trace.
  LOG

  test "the reason is taken from what the tool said went wrong" do
    detail = Build.why_it_failed(GRADLE, "gradle assembleRelease exited 1")

    assert_includes detail, "gradle assembleRelease exited 1"
    assert_includes detail, "splashscreen_image.png",
                    "the name of the file that failed is the whole answer"
  end

  test "a log with no marker still gives the end of it" do
    detail = Build.why_it_failed("line one\nline two\nsomething broke", "exited 1")

    assert_includes detail, "something broke"
  end

  test "no log at all leaves the summary alone" do
    assert_equal "exited 1", Build.why_it_failed(nil, "exited 1")
    assert_equal "exited 1", Build.why_it_failed("   \n  ", "exited 1")
  end

  test "the failure a build records carries it" do
    app = MobileApp.create!(domain: "example.test", bundle_identifier: "a.b", name: "A")
    build = Build.create!(mobile_app: app, domain: "example.test", platform: "android",
                          state: Build::QUEUED)

    build.record_failure!(error: "gradle assembleRelease exited 1", log: GRADLE)

    assert_includes build.reload.last_error, "AAPT"
    assert_includes build.build_attempts.last.detail, "AAPT",
                    "the attempt is what a person reads, so it is where the reason belongs"
  end
end

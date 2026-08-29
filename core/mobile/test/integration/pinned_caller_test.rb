# frozen_string_literal: true

require "test_helper"

# What a caller that speaks for one domain may ask for.
#
# The Backoffice is run by an operator and sees every domain. The Base App is
# inside one. Both reach this service with a bearer token and nothing else, so
# the difference between them is a decision made here, and it is the sort of
# decision that fails quietly: a caller handed too much answers 200 and looks
# exactly like a caller handed the right amount.
class PinnedCallerTest < ActionDispatch::IntegrationTest
  OPERATOR = "operator-token-for-tests"
  OWNER = "base-token-for-tests"

  setup do
    @previous = ENV["SIBERIAN_CALLERS"]
    ENV["SIBERIAN_CALLERS"] = "orchestrator=#{OPERATOR},base=#{OWNER}"
    Siberian::ServiceIdentity.reset!

    Build.delete_all
    MobileApp.delete_all

    @mine = MobileApp.create!(domain: "mine.test", name: "Mine",
                              bundle_identifier: "test.mine", version: "1.0.0")
    @theirs = MobileApp.create!(domain: "theirs.test", name: "Theirs",
                                bundle_identifier: "test.theirs", version: "1.0.0")

    @my_build = @mine.builds.create!(domain: "mine.test", platform: Build::WEB)
    @their_build = @theirs.builds.create!(domain: "theirs.test", platform: Build::WEB)
  end

  teardown do
    ENV["SIBERIAN_CALLERS"] = @previous
    Siberian::ServiceIdentity.reset!
  end

  def as(token, path)
    get path, headers: { "Authorization" => "Bearer #{token}" }
  end

  test "an operator sees every domain's builds" do
    as OPERATOR, "/admin/builds"

    assert_response :success
    assert_equal %w[mine.test theirs.test],
                 JSON.parse(body)["builds"].map { |b| b["domain"] }.uniq.sort
  end

  # The whole point. Asking for everything is how a caller written for one
  # domain would accidentally read the system, and it is a plausible mistake to
  # make: the parameter is optional and omitting it used to mean "all of them".
  test "a pinned caller asking for everything is refused rather than served" do
    as OWNER, "/admin/builds"

    assert_response :bad_request
    assert_match "must name the domain", JSON.parse(body)["error"]
  end

  test "a pinned caller that names its domain gets that domain and only it" do
    as OWNER, "/admin/builds?domain=mine.test"

    assert_response :success
    assert_equal ["mine.test"], JSON.parse(body)["builds"].map { |b| b["domain"] }.uniq
  end

  # A count rather than a list, and deliberately across every domain: there is
  # one builder, the page that shows this says so, and a position in the queue
  # is only useful if it counts the builds actually ahead.
  test "the queue depth it is told is the real one" do
    as OWNER, "/admin/builds?domain=mine.test"

    assert_equal 2, JSON.parse(body)["queued"]
  end

  test "a waiting build is told where it is in line" do
    as OWNER, "/admin/builds?domain=mine.test"

    assert_equal 1, JSON.parse(body)["builds"].first["position"]
  end

  test "a finished build has no position, because it is not waiting for anything" do
    @my_build.update!(state: Build::SUCCEEDED)
    as OWNER, "/admin/builds?domain=mine.test"

    assert_nil JSON.parse(body)["builds"].first["position"]
  end

  test "a pinned caller cannot read a build belonging to somebody else" do
    as OWNER, "/admin/builds/#{@their_build.id}?domain=mine.test"

    assert_response :not_found
  end

  # The same answer as a build that does not exist. Saying "not yours" would
  # confirm that it is somebody's, which is the thing being kept back.
  test "and cannot tell that build apart from one that never existed" do
    as OWNER, "/admin/builds/#{@their_build.id}?domain=mine.test"
    theirs = body

    as OWNER, "/admin/builds/999999?domain=mine.test"

    assert_equal theirs, body
  end

  test "a pinned caller cannot cancel a build belonging to somebody else" do
    post "/admin/builds/#{@their_build.id}/cancel",
         headers: { "Authorization" => "Bearer #{OWNER}" },
         params: { domain: "mine.test" }

    assert_response :not_found
    assert_equal Build::QUEUED, @their_build.reload.state
  end

  test "a pinned caller is not told which other domains exist" do
    as OWNER, "/admin/apps"

    assert_response :success
    parsed = JSON.parse(body)
    assert_empty parsed["apps"]
    # The catalogue is what an app can be built with rather than what anybody
    # has built, so it is the same for everybody and is what this call is for.
    assert_not_empty parsed["catalogue"]
  end

  test "an operator still is" do
    as OPERATOR, "/admin/apps"

    assert_equal %w[mine.test theirs.test], JSON.parse(body)["apps"].map { |a| a["domain"] }.sort
  end
end

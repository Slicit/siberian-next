# frozen_string_literal: true

require "test_helper"

# The page an app owner builds their phone app on.
#
# It spent its whole life answering 200 while showing nothing: the Mobile
# service refused it and the page turned the refusal into an empty list. So the
# tests that matter here are not "does it answer" but "what does it say", and
# "what did it ask for".
class PhoneAppTest < ShellTest
  APP = {
    "ok" => true, "domain" => DOMAIN, "name" => "The App",
    "bundle_identifier" => "test.the.app", "version" => "1.0.0", "build_number" => 3,
    "theme" => "midnight", "primary_color" => "#334455", "capabilities" => []
  }.freeze

  def queue(builds: [], queued: 0, building: 0)
    { "ok" => true, "queued" => queued, "building" => building, "builds" => builds }
  end

  def build(state: "succeeded", platform: "web", **rest)
    { "id" => 7, "domain" => DOMAIN, "platform" => platform, "state" => state,
      "created_at" => "2026-08-30T10:00:00Z", "finished_at" => "2026-08-30T10:01:00Z",
      "artifact_path" => "preview", "artifact_bytes" => 1024 }.merge(rest)
  end

  # Configuring the app is not using the product. Somebody who can open the
  # modules still cannot decide what the app may do to a phone.
  test "app.use alone does not open the phone app page" do
    as_owner(person: FakePerson.new(permissions: %w[app.use])) do
      get "/app", headers: headers
    end

    assert_response :forbidden
  end

  # The invariant everything else rests on. The Mobile service pins this caller
  # to one domain and cannot check the claim, so the Base App never passing a
  # domain it was handed is the half that can be checked, and this is where.
  test "every question it asks names the domain the Router put on the request" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do |mobile|
      get "/app", headers: headers(domain: "somewhere-else.test")

      assert_equal ["somewhere-else.test"], mobile.domains_named.uniq
    end
  end

  test "a domain in the query string is not the domain it asks about" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do |mobile|
      get "/app?domain=victim.test", headers: headers

      assert_equal [DOMAIN], mobile.domains_named.uniq
    end
  end

  test "and neither is one in the body of a build request" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do |mobile|
      post "/app/build", params: { domain: "victim.test", platform: "web" }, headers: headers

      queued = mobile.asked.find { |call| call.first == :queue_build }
      assert_equal DOMAIN, queued[1][:domain]
    end
  end

  test "the builds it lists are the ones the queue gave it" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue(builds: [build(platform: "android")]))) do
      get "/app", headers: headers
    end

    assert_response :success
    assert_no_match "Nothing built yet", response.body
  end

  # The bug this page had. A refusal and an empty queue are different facts and
  # were the same sentence, which is why nothing ever looked wrong.
  test "a queue that refuses is not reported as a queue with nothing in it" do
    as_owner(mobile: FakeMobile.new(app: APP,
                                    builds: { "ok" => false, "error" => "base is not permitted here" })) do
      get "/app", headers: headers
    end

    assert_response :success
    assert_match "did not answer", response.body
    assert_no_match "Nothing built yet", response.body
  end

  test "a queue that is not there at all says the same thing" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: nil)) do
      get "/app", headers: headers
    end

    assert_match "did not answer", response.body
  end

  test "an empty queue does say there is nothing built yet" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do
      get "/app", headers: headers
    end

    assert_match "Nothing built yet", response.body
    assert_no_match "did not answer", response.body
  end

  test "a waiting build is told where it is in line" do
    waiting = build(state: "queued", platform: "android", "position" => 3)

    as_owner(mobile: FakeMobile.new(app: APP, builds: queue(builds: [waiting], queued: 3))) do
      get "/app", headers: headers
    end

    assert_match "number 3 in line", response.body
  end

  test "the shared queue is described when anything is in it" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue(queued: 2, building: 1))) do
      get "/app", headers: headers
    end

    assert_match "1 build running", response.body
    assert_match "2 waiting", response.body
  end

  test "and is not mentioned when it is empty" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do
      get "/app", headers: headers
    end

    assert_no_match "Right now:", response.body
  end
end

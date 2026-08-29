# frozen_string_literal: true

require "test_helper"

# Describing an app, accepting what was proposed, and what the page says when
# the Mobile service says no.
class PhoneAppEditingTest < ShellTest
  # A description in, a proposal out, and nothing applied. That is why suggest
  # and apply are separate actions: what somebody accepts has to be exactly what
  # they were shown.
  test "asking for a proposal changes nothing" do
    proposal = { "name" => "Field Service", "bundle_identifier" => "test.field",
                 "primary_color" => "#112233", "capabilities" => [] }

    as_owner(mobile: FakeMobile.new(app: APP, builds: queue,
                                    suggest: { "ok" => true, "proposal" => proposal })) do |mobile|
      post "/app/suggest", params: { description: "for engineers" }, headers: headers

      assert_response :success
      assert_match "Field Service", response.body
      assert_empty mobile.asked.select { |call| %i[save_app set_capability].include?(call.first) }
    end
  end

  test "an assistant that is not configured is said so rather than shown as an empty proposal" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue,
                                    suggest: { "ok" => false, "error" => "no assistant configured" })) do
      post "/app/suggest", params: { description: "anything" }, headers: headers
    end

    assert_response :success
    assert_match "no assistant configured", response.body
  end

  test "an assistant that does not answer at all is also said" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue, suggest: nil)) do
      post "/app/suggest", params: { description: "anything" }, headers: headers
    end

    assert_match "did not answer", response.body
  end

  # A capability somebody unticked is not in the parameters at all, so applying
  # switches on exactly what was ticked and nothing else.
  test "applying switches on the capabilities that were ticked and no others" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do |mobile|
      patch "/app", params: { name: "Field Service", bundle_identifier: "test.field",
                              capabilities: %w[camera location] }, headers: headers

      switched = mobile.asked.select { |call| call.first == :set_capability }.map { |call| call[2] }
      assert_equal %w[camera location], switched
    end

    assert_redirected_to "/app"
  end

  test "and says which ones it switched on" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do
      patch "/app", params: { name: "X", capabilities: %w[camera] }, headers: headers
    end

    assert_match "camera", flash[:notice]
  end

  test "a save the Mobile service rejects is reported as a failure, not a success" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue, save_app: nil)) do
      patch "/app", params: { name: "X" }, headers: headers
    end

    assert_equal "That did not save.", flash[:alert]
    assert_nil flash[:notice]
  end

  # The one that used to fail silently on this page. A refused build looked
  # exactly like a build nobody had asked for.
  test "a build the Mobile service refuses says why" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue,
                                    queue_build: { "ok" => false, "error" => "base is not permitted here" })) do
      post "/app/build", params: { platform: "android" }, headers: headers
    end

    assert_equal "base is not permitted here", flash[:alert]
    assert_nil flash[:notice]
  end

  test "a build that is queued says where it is in line" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue,
                                    queue_build: { "ok" => true, "position" => 4 })) do
      post "/app/build", params: { platform: "android" }, headers: headers
    end

    assert_equal "Build queued, number 4 in line.", flash[:notice]
  end

  # A capability with settings it cannot work without is refused with the list,
  # and the list is the useful half.
  test "a build refused for missing settings names them" do
    refusal = { "ok" => false, "error" => "some enabled capabilities are missing settings",
                "misconfigured" => [{ "capability" => "push", "missing" => %w[key sender] }] }

    as_owner(mobile: FakeMobile.new(app: APP, builds: queue, queue_build: refusal)) do
      post "/app/build", params: { platform: "android" }, headers: headers
    end

    assert_match "push needs key and sender", flash[:alert]
  end

  test "uploading a splash with no file at all asks for one" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do
      post "/app/splash", headers: headers
    end

    assert_equal "Choose a file first.", flash[:alert]
  end

  # Which upload it is comes from the field the form used, never from sniffing
  # the file. An animation and an image are different endpoints on the Mobile
  # service and guessing between them would be a decision made in the wrong
  # place.
  test "the field the form used decides which upload it is" do
    file = Rack::Test::UploadedFile.new(StringIO.new("not really a png"), "image/png", original_filename: "s.png")

    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do |mobile|
      post "/app/splash", params: { image: file, background: "#fff" }, headers: headers

      assert_equal :upload_splash, mobile.asked.first.first
    end
  end

  test "the app that has never been configured says so instead of drawing an empty form" do
    as_owner(mobile: FakeMobile.new(app: { "ok" => false, "error" => "no app for that domain" },
                                    builds: queue)) do
      get "/app", headers: headers
    end

    assert_response :success
    assert_match "No app for this domain yet", response.body
  end
end

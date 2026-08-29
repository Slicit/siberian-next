# frozen_string_literal: true

require "test_helper"

# The preview, the theme, and what happens when the Mobile service says no.
class PhoneAppPreviewTest < ShellTest
  def web_build(state: "succeeded")
    { "id" => 9, "domain" => DOMAIN, "platform" => "web", "state" => state,
      "created_at" => "2026-08-30T10:00:00Z", "finished_at" => "2026-08-30T10:01:00Z" }
  end

  test "the frame is offered once a web build has finished" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue(builds: [web_build]))) do
      get "/app", headers: headers
    end

    assert_match "<iframe", response.body
    assert_match "Rebuild preview", response.body
  end

  # index.html by name rather than the bare route. The export links its assets
  # relatively so it can be served under any prefix, and a browser resolves
  # those against the directory it believes it is in: at /app/preview it asks
  # for /app/_expo/... and gets nothing. A blank white phone, and no error.
  test "the frame names index.html so the export's own assets resolve" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue(builds: [web_build]))) do
      get "/app", headers: headers
    end

    assert_match %r{src="/app/preview/index\.html\?theme=}, response.body
  end

  test "it opens on the theme that is saved" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue(builds: [web_build]))) do
      get "/app", headers: headers
    end

    assert_match "index.html?theme=midnight", response.body
    assert_match %r{<option selected="selected" value="midnight">}, response.body
  end

  test "a web build still running does not pretend to be a preview" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue(builds: [web_build(state: "building")]))) do
      get "/app", headers: headers
    end

    assert_match "The preview is building", response.body
    assert_no_match "<iframe", response.body
  end

  test "and with no web build at all it says so rather than showing an empty frame" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do
      get "/app", headers: headers
    end

    assert_match "No preview built yet", response.body
    assert_no_match "<iframe", response.body
  end

  test "the preview serves what the Mobile service returned" do
    as_owner(mobile: FakeMobile.new(preview: ["<html>the app</html>", "text/html"])) do
      get "/app/preview/index.html", headers: headers
    end

    assert_response :success
    assert_equal "text/html", response.media_type
    assert_equal "<html>the app</html>", response.body
  end

  # Rails refuses to send a JavaScript response to a request it cannot prove
  # came from here. Right for a page about the person asking, wrong for a build
  # artifact, and the symptom is a blank phone rather than anything red.
  test "including its JavaScript, which forgery protection would otherwise refuse" do
    as_owner(mobile: FakeMobile.new(preview: ["console.log(1)", "text/javascript"])) do
      get "/app/preview/_expo/static/js/web/index-abc.js", headers: headers
    end

    assert_response :success
    assert_equal "text/javascript", response.media_type
  end

  test "the preview asks for the domain on the request, never one in the path" do
    as_owner(mobile: FakeMobile.new(preview: ["x", "text/plain"])) do |mobile|
      get "/app/preview/index.html", headers: headers(domain: "elsewhere.test")

      assert_equal [:preview, "elsewhere.test", "index.html"], mobile.asked.first
    end
  end

  test "a preview the Mobile service does not have is a 404, not a blank page" do
    as_owner(mobile: FakeMobile.new(preview: nil)) do
      get "/app/preview/index.html", headers: headers
    end

    assert_response :not_found
  end

  test "keeping a theme sends only the theme" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do |mobile|
      patch "/app/theme", params: { theme: "meadow" }, headers: headers

      saved = mobile.asked.find { |call| call.first == :save_app }
      assert_equal DOMAIN, saved[1]
      assert_equal({ theme: "meadow" }, saved[2])
    end

    assert_redirected_to "/app"
    assert_equal "Now using Meadow.", flash[:notice]
  end

  # A theme that no longer exists renders in the default rather than failing, so
  # the sentence has to come from the same lookup the app uses.
  test "a theme nobody has heard of does not take the page down" do
    as_owner(mobile: FakeMobile.new(app: APP, builds: queue)) do
      patch "/app/theme", params: { theme: "chartreuse" }, headers: headers
    end

    assert_redirected_to "/app"
  end
end

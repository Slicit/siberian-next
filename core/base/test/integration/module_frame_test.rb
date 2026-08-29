# frozen_string_literal: true

require "test_helper"

# One module, framed inside the shell.
#
# The frame boundary is the isolation between third-party code and the product,
# so the tests here are mostly about the door: who may open it, what happens to
# a module that is not installed, and where the frame is pointed.
class ModuleFrameTest < ShellTest
  def directory_with(*capabilities)
    FakeDirectory.new(capabilities: capabilities)
  end

  test "a module that is not installed sends somebody home rather than erroring" do
    as_owner(directory: directory_with) do
      get "/m/notes-all", headers: headers
    end

    assert_redirected_to "/"
    assert_equal "That feature is not installed.", flash[:alert]
  end

  # A hidden link is not access control. The sidebar filters, and somebody can
  # always type the URL, so the check is here as well and this is the half that
  # actually stops anybody.
  test "somebody without the module's permission is refused even typing the URL" do
    as_owner(person: FakePerson.new(permissions: %w[app.use]),
             directory: directory_with(a_capability)) do
      get "/m/notes-all", headers: headers
    end

    assert_response :forbidden
  end

  test "somebody with it gets the module framed" do
    as_owner(person: FakePerson.new(permissions: %w[app.use module.example-notes.use]),
             directory: directory_with(a_capability)) do
      get "/m/notes-all", headers: headers
    end

    assert_response :success
    assert_match "https://example-notes.apps.owner.test", response.body
  end

  # The module is served from its own origin so the browser enforces the
  # boundary rather than a convention. If this ever became a same-origin path
  # the isolation would be gone and nothing else would notice.
  test "the frame points at the module's own origin, not a path on this one" do
    as_owner(person: FakePerson.new(permissions: %w[app.use module.example-notes.use]),
             directory: directory_with(a_capability)) do
      get "/m/notes-all", headers: headers
    end

    frame = response.body[/<iframe[^>]*src="([^"]+)"/, 1]
    assert_equal "https://example-notes.apps.owner.test", frame
  end

  test "a module page can be deep linked rather than always opening at its front door" do
    as_owner(person: FakePerson.new(permissions: %w[app.use module.example-notes.use]),
             directory: directory_with(a_capability)) do
      get "/m/notes-all/notes/42", headers: headers
    end

    assert_response :success
    assert_match "https://example-notes.apps.owner.test/notes/42", response.body
  end

  test "it is found by its id as well as its slug" do
    as_owner(person: FakePerson.new(permissions: %w[app.use module.example-notes.use]),
             directory: directory_with(a_capability)) do
      get "/m/notes.all", headers: headers
    end

    assert_response :success
  end
end

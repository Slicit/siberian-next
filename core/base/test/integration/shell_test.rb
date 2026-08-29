# frozen_string_literal: true

require "test_helper"

# The shell every page is drawn inside: who gets in, and what they see.
class ShellAccessTest < ShellTest
  test "somebody who is not signed in is sent to sign in" do
    standing_in(Siberian::AuthClient, FakeAuth.new(nil)) do
      get "/", headers: headers
    end

    assert_redirected_to %r{/login\?return_to=}
  end

  # Signed in is not allowed in. The distinction exists because an account on a
  # domain is not by itself permission to use the product on it.
  test "somebody signed in without app.use is told so rather than shown an empty product" do
    as_owner(person: FakePerson.new(permissions: [])) do
      get "/", headers: headers
    end

    assert_response :forbidden
  end

  test "somebody with app.use gets the product" do
    as_owner { get "/", headers: headers }

    assert_response :success
  end

  # The menu is loaded for every page rather than by each controller that
  # remembers to. It was the second kind: the phone app page did not set it, the
  # layout tolerated the absence, and the modules quietly vanished from one page.
  test "the menu is loaded on the phone app page too, not only the home page" do
    groups = [["Main", []]]

    as_owner(directory: FakeDirectory.new(groups: groups)) do
      get "/app", headers: headers
    end

    assert_response :success
    assert_equal groups, @controller.view_assigns["groups"]
  end

  # Never fatal. A shell that will not render because the directory is briefly
  # unreachable is worse than one with an empty menu and a page that works.
  test "a directory that raises leaves an empty menu and a page that still renders" do
    as_owner(directory: FakeDirectory.new(raises: Errno::ECONNREFUSED)) do
      get "/", headers: headers
    end

    assert_response :success
    assert_empty @controller.view_assigns["groups"]
  end
end

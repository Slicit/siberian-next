# frozen_string_literal: true

require "test_helper"

class SessionsTest < ActionDispatch::IntegrationTest
  # Production always has a Router in front supplying the domain, and the
  # cookie is scoped to it. A test that skips that is testing a path nobody
  # runs.
  DOMAIN_HEADERS = { "X-Siberian-Domain" => "example.test" }.freeze

  setup do
    host! "app.example.test"
    @user = User.create!(email: "alex@example.test", password: "password123", name: "Alex")
  end

  def sign_in(password: "password123", **extra)
    post login_path, params: { email: "alex@example.test", password: password }.merge(extra),
                     headers: DOMAIN_HEADERS
  end

  test "signing in sets a session cookie and redirects" do
    sign_in

    assert_response :redirect
    assert cookies[:siberian_session].present?
  end

  test "a wrong password says the same thing as an unknown email" do
    sign_in(password: "wrong")
    wrong_password = response.body

    post login_path, params: { email: "nobody@example.test", password: "password123" }, headers: DOMAIN_HEADERS
    unknown_email = response.body

    assert_response :unprocessable_entity
    assert_equal wrong_password.include?("do not match"), unknown_email.include?("do not match"),
                 "differing messages turn a password guess into account enumeration"
  end

  test "the internal endpoint identifies the signed-in user to other services" do
    sign_in
    token = cookies[:siberian_session]

    get "/internal/session", headers: { "X-Siberian-Session" => token }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["authenticated"]
    assert_equal "alex@example.test", body.dig("user", "email")
    refute body.dig("user").key?("password_digest")
  end

  test "the internal endpoint refuses an unknown session" do
    get "/internal/session", headers: { "X-Siberian-Session" => "nope" }

    assert_response :unauthorized
    refute JSON.parse(response.body)["authenticated"]
  end

  test "signing out revokes the session for everyone, not just this browser" do
    sign_in
    token = cookies[:siberian_session]

    delete logout_path, headers: DOMAIN_HEADERS

    get "/internal/session", headers: { "X-Siberian-Session" => token }
    assert_response :unauthorized
  end

  test "an off-domain return_to is ignored" do
    sign_in(return_to: "https://evil.example.com/steal")

    assert_response :redirect
    refute_includes response.location, "evil.example.com"
  end

  test "a relative return_to is honoured" do
    sign_in(return_to: "/somewhere")

    assert_redirected_to "/somewhere"
  end
end

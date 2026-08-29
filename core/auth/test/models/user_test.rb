# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "emails are stored normalised, so case cannot create a second account" do
    user = User.create!(email: "  Alex@Example.TEST ", password: "password123")

    assert_equal "alex@example.test", user.email
    assert_raises(ActiveRecord::RecordInvalid) do
      User.create!(email: "ALEX@EXAMPLE.TEST", password: "password123")
    end
  end

  test "a short password is refused" do
    user = User.new(email: "a@example.test", password: "short")

    refute user.valid?
    assert_includes user.errors.attribute_names, :password
  end

  test "the identity handed to other services carries no secrets" do
    user = User.create!(email: "a@example.test", password: "password123", name: "Alex")

    identity = user.to_identity

    # The shape grew when access control arrived, and again when identities
    # got a stable name. This asserts what must always be there and what must
    # never be, rather than an exact key list: the comment already said that
    # was the intent, and the assertion underneath it said otherwise and
    # failed the next time a field was added.
    assert_empty %i[subject id email name active operator permissions denied] - identity.keys
    refute identity.key?(:password_digest)
    refute identity.key?(:otp_secret)
    refute identity.values.any? { |value| value.to_s.include?("$2a$") }
  end

  test "a user with no name is known by the local part of their email" do
    user = User.create!(email: "alex@example.test", password: "password123")

    assert_equal "alex", user.display_name
  end
end

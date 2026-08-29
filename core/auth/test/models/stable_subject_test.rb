# frozen_string_literal: true

require "test_helper"

# The name a module keys its rows by.
#
# Modules used to key by email address, which is how somebody signs in rather
# than who they are. Two consequences followed: an account could not be ended
# and its address freed, because the next person to claim it would inherit
# everything the last one made; and changing an address would have orphaned all
# of it at once, in every module, with nothing reporting it.
class StableSubjectTest < ActiveSupport::TestCase
  def app_user(email: "someone@example.test", domain: "owner.test")
    AppUser.create!(domain: domain, email: email, password: "a-good-password-1")
  end

  test "an app user is named when it is created" do
    assert_match(/\Aau_[0-9a-f]{32}\z/, app_user.subject)
  end

  test "a core user is named too, because operators use modules as well" do
    user = User.create!(email: "op@example.test", password: "a-good-password-1")

    assert_match(/\Acu_[0-9a-f]{32}\z/, user.subject)
  end

  # The reason for the prefixes rather than a bare id. The two tables have
  # separate sequences, so operator 7 and app user 7 both exist, and a module
  # keying by a bare id would put their rows in one pile. The first symptom
  # would be somebody opening a module and seeing another person's data.
  test "an operator and an app user with the same id are still told apart" do
    person = app_user
    operator = User.create!(email: "same-number@example.test", password: "a-good-password-1")

    assert_not_equal person.subject, operator.subject
    assert_not_equal person.subject[0, 3], operator.subject[0, 3]
  end

  test "it does not change when anything else about the person does" do
    person = app_user
    before = person.subject

    person.update!(name: "A New Name")

    assert_equal before, person.reload.subject
  end

  # The property the whole thing exists for. Nothing here can change an address
  # yet, so this asserts the shape rather than a feature: whatever the address
  # becomes, the name a module keyed its rows by is the same one.
  test "and it survives the address changing" do
    person = app_user
    before = person.subject

    person.update!(email: "moved-house@example.test")

    assert_equal before, person.reload.subject
  end

  test "two people never share one" do
    first = app_user(email: "first@example.test")
    second = app_user(email: "second@example.test")

    assert_not_equal first.subject, second.subject
  end

  # A record restored from a backup, or moved between deployments, keeps the
  # name every module already knows it by. Generating a fresh one would orphan
  # everything that person made.
  test "one that is already set is kept" do
    person = AppUser.create!(domain: "owner.test", email: "restored@example.test",
                             password: "a-good-password-1", subject: "au_" + ("a" * 32))

    assert_equal "au_#{'a' * 32}", person.subject
  end

  test "it is handed to whoever asks for the identity" do
    person = app_user

    assert_equal person.subject, person.to_identity[:subject]
  end
end

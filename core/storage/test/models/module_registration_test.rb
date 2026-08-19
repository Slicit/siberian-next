# frozen_string_literal: true

require "test_helper"

class ModuleRegistrationTest < ActiveSupport::TestCase
  def register(**overrides)
    ModuleRegistration.register!(**{
      module_name: "demo-tasks",
      module_uuid: "abc123",
      spaces: %w[files public]
    }.merge(overrides))
  end

  test "registering returns a token that is never stored in readable form" do
    registration, token = register

    assert token.present?
    refute_equal token, registration.token_digest
    refute_includes registration.attributes.values.map(&:to_s), token
  end

  test "the token authenticates the module it was issued to" do
    registration, token = register

    assert_equal registration, ModuleRegistration.authenticate(token)
  end

  test "a wrong or blank token authenticates nobody" do
    register

    assert_nil ModuleRegistration.authenticate("not-the-token")
    assert_nil ModuleRegistration.authenticate("")
    assert_nil ModuleRegistration.authenticate(nil)
  end

  test "a revoked module can no longer authenticate" do
    registration, token = register
    registration.update!(revoked_at: Time.current)

    assert_nil ModuleRegistration.authenticate(token)
  end

  test "re-registering replaces the token rather than adding a second module" do
    _first, old_token = register
    _second, new_token = register

    assert_equal 1, ModuleRegistration.count
    assert_nil ModuleRegistration.authenticate(old_token), "the old token must stop working"
    assert ModuleRegistration.authenticate(new_token)
  end

  test "a module is confined to the spaces it was granted" do
    registration, = register(spaces: %w[files])

    assert registration.allows?("files")
    refute registration.allows?("public")
    refute registration.allows?("tmp")
  end

  test "an unknown space is rejected at registration" do
    assert_raises(ActiveRecord::RecordInvalid) { register(spaces: %w[files secrets]) }
  end

  test "quota is expressed in bytes for the code that enforces it" do
    registration, = register(quota_mb: 2)

    assert_equal 2 * 1024 * 1024, registration.quota_bytes
  end
end

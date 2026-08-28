# frozen_string_literal: true

require_relative "test_helper"
require "lib/service_identity"

# Who is calling, and what they may therefore do.
#
# The tests worth having here are the refusals. Accepting the right token is one
# line; the reason this code exists is that the old shared token accepted
# everything from everybody, so what matters is that a token which is valid
# somewhere is refused everywhere else.
class ServiceIdentityTest < Minitest::Test
  def setup = reset_env
  def teardown = reset_env

  def reset_env
    ENV.delete("SIBERIAN_CALLERS")
    ENV.delete("SIBERIAN_CALLEES")
    ENV.delete("SIBERIAN_SERVICE_NAME")
    ENV.delete("SIBERIAN_ADMIN_TOKEN")
    Siberian::ServiceIdentity.reset!
  end

  def with(callers: nil, callees: nil, admin: nil)
    ENV["SIBERIAN_CALLERS"] = callers if callers
    ENV["SIBERIAN_CALLEES"] = callees if callees
    ENV["SIBERIAN_ADMIN_TOKEN"] = admin if admin
    Siberian::ServiceIdentity.reset!
    yield
  end

  def test_identifies_a_configured_caller
    with(callers: "orchestrator=abc,mobile=def") do
      assert_equal "orchestrator", Siberian::ServiceIdentity.identify("abc")
      assert_equal "mobile", Siberian::ServiceIdentity.identify("def")
    end
  end

  def test_refuses_a_token_it_does_not_know
    with(callers: "orchestrator=abc") do
      assert_nil Siberian::ServiceIdentity.identify("nope")
    end
  end

  def test_refuses_an_empty_token
    with(callers: "orchestrator=abc") do
      assert_nil Siberian::ServiceIdentity.identify("")
      assert_nil Siberian::ServiceIdentity.identify(nil)
    end
  end

  # The whole point of the change. Under the old scheme every service held one
  # token that worked everywhere, so a service compromised here could act as
  # anybody there.
  def test_a_token_for_one_pair_does_not_work_for_another
    orchestrator_to_storage = "s3cret-storage"

    with(callers: "orchestrator=#{orchestrator_to_storage}") do
      assert_equal "orchestrator", Siberian::ServiceIdentity.identify(orchestrator_to_storage)
    end

    # The same caller, a different callee, a different secret.
    with(callers: "orchestrator=s3cret-database") do
      assert_nil Siberian::ServiceIdentity.identify(orchestrator_to_storage),
                 "a credential for one service must be useless against another"
    end
  end

  def test_presents_the_right_token_per_callee
    with(callees: "storage=to-storage,auth=to-auth") do
      assert_equal "to-storage", Siberian::ServiceIdentity.token_for(:storage)
      assert_equal "to-auth", Siberian::ServiceIdentity.token_for("auth")
    end
  end

  # Whitespace, because compose writes these with a folded YAML scalar and the
  # result has a space after every comma.
  def test_tolerates_the_spacing_compose_produces
    with(callers: "orchestrator=abc, mobile=def") do
      assert_equal "mobile", Siberian::ServiceIdentity.identify("def")
    end
  end

  def test_ignores_malformed_entries_rather_than_inventing_one
    with(callers: "orchestrator=abc,broken,=nameless,empty=") do
      assert_equal "orchestrator", Siberian::ServiceIdentity.identify("abc")
      assert_nil Siberian::ServiceIdentity.identify("")
      refute Siberian::ServiceIdentity.callers.key?("empty")
      refute Siberian::ServiceIdentity.callers.key?("")
    end
  end

  # A deployment that has the new code and the old environment keeps working,
  # loudly. Without this the upgrade has to be simultaneous everywhere.
  def test_falls_back_to_the_shared_token_when_nothing_is_configured
    with(admin: "old-shared") do
      assert Siberian::ServiceIdentity.legacy?
      assert_equal Siberian::ServiceIdentity::LEGACY,
                   Siberian::ServiceIdentity.identify("old-shared")
      assert_nil Siberian::ServiceIdentity.identify("something-else")
    end
  end

  # And once callers are configured, the old shared token stops being special.
  # This is what makes the migration finish rather than linger.
  def test_the_shared_token_is_refused_once_callers_are_configured
    with(callers: "orchestrator=abc", admin: "old-shared") do
      refute Siberian::ServiceIdentity.legacy?
      assert_nil Siberian::ServiceIdentity.identify("old-shared")
    end
  end

  def test_token_for_falls_back_to_the_shared_token_when_unconfigured
    with(admin: "old-shared") do
      assert_equal "old-shared", Siberian::ServiceIdentity.token_for(:storage)
    end
  end
end

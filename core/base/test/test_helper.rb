ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"


require_relative "support/fake_core"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all
  end
end

# The Base App owns no data, so every one of its tests is a page drawn from
# somebody else's answer. This puts stand-ins in front of all three services and
# lets a test say only what it cares about.
class ShellTest < ActionDispatch::IntegrationTest
  DOMAIN = "owner.test"

  # A saved app, as the Mobile service reports one. Shared rather than repeated
  # so that a field changing shape breaks every test that depends on it at once
  # rather than one at a time.
  APP = {
    "ok" => true, "domain" => DOMAIN, "name" => "The App",
    "bundle_identifier" => "test.the.app", "version" => "1.0.0", "build_number" => 3,
    "theme" => "midnight", "primary_color" => "#334455", "capabilities" => []
  }.freeze

  # `queued` and `building` name the native lane, because that is the one the
  # Builds section reports. The totals are kept alongside the breakdown the
  # way the Mobile service sends them.
  def queue(builds: [], queued: 0, building: 0, previews_queued: 0, previews_building: 0)
    { "ok" => true,
      "queued" => queued + previews_queued,
      "building" => building + previews_building,
      "lanes" => {
        "native" => { "queued" => queued, "building" => building },
        "preview" => { "queued" => previews_queued, "building" => previews_building }
      },
      "builds" => builds }
  end

  def a_build(state: "succeeded", platform: "web", **rest)
    { "id" => 7, "domain" => DOMAIN, "platform" => platform, "state" => state,
      "created_at" => "2026-08-30T10:00:00Z", "finished_at" => "2026-08-30T10:01:00Z",
      "artifact_path" => "preview", "artifact_bytes" => 1024 }.merge(rest)
  end

  # The Router puts the domain on every request. Sending it here rather than
  # relying on a fallback is the point: several of these tests are about the
  # Base App using this and never a parameter.
  def headers(domain: DOMAIN)
    { "X-Siberian-Domain" => domain }
  end

  # Signed in, allowed in, with a menu and a Mobile service, unless a test says
  # otherwise. Yielded so a test can read what the fakes were asked.
  def as_owner(person: FakePerson.new, mobile: FakeMobile.new, directory: FakeDirectory.new)
    standing_in(Siberian::AuthClient, FakeAuth.new(person)) do
      standing_in(Siberian::MobileClient, mobile) do
        standing_in(CapabilityDirectory, directory) do
          yield mobile
        end
      end
    end
  end

  # Forgery protection is off in the test environment, which is right for
  # almost everything and wrong for the one action that exists because of it.
  # An example that needs the real behaviour asks for it here.
  def protecting
    was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = was
  end

  # Minitest 6 no longer ships Object#stub, and the alternatives are adding a
  # gem to every service or giving the app class-level slots it only needs
  # because of its tests. Swapping one constructor for the length of a block is
  # the smaller price, and it is confined to here.
  def standing_in(klass, double)
    original = klass.method(:new)
    klass.define_singleton_method(:new) { |*, **| double }
    yield
  ensure
    klass.define_singleton_method(:new, original)
  end
end

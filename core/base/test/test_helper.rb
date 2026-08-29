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

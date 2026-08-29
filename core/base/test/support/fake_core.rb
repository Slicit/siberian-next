# frozen_string_literal: true

# Stand-ins for the three services the shell talks to.
#
# The Base App owns no data. Every page it draws is somebody else's answer over
# HTTP: who is signed in comes from Auth, the menu from the Orchestrator, the
# phone app and its builds from Mobile. So these tests are about what it does
# with an answer, including the answers nothing else exercises: a service that
# refuses, and a service that is not there at all.

# Somebody signed in, built from the real Identity rather than a hand-rolled
# double. A stand-in that invents its own shape drifts from the thing it stands
# for, and the first symptom is a test passing against a page that would fail.
module FakePerson
  def self.new(email: "owner@example.test", name: "The Owner",
               permissions: %w[app.use core.mobile.manage])
    Siberian::AuthClient::Identity.new(
      id: 1, email: email, name: name, active: true, operator: false,
      permissions: Siberian::Permissions::Set.new(permissions)
    )
  end
end

class FakeAuth
  def initialize(person) = @person = person
  def identify(_token) = @person
end
# Records what it was asked, because the point of several of these tests is not
# the answer but the question: the Base App must never pass a domain it was
# handed, only the one the Router put on the request.
class FakeMobile
  attr_reader :asked

  # `answers` is keyed by method name. Anything not named answers nil, which is
  # what an unreachable service looks like from here and is deliberately the
  # default rather than an empty success.
  def initialize(**answers)
    @answers = answers
    @asked = []
  end

  def app(domain)
    record(:app, domain)
    @answers[:app]
  end

  def apps
    record(:apps)
    @answers.fetch(:apps, { "catalogue" => [], "ok" => true })
  end

  def builds(domain: nil)
    record(:builds, domain)
    @answers[:builds]
  end

  def save_app(domain, attributes)
    record(:save_app, domain, attributes)
    @answers.fetch(:save_app, { "ok" => true })
  end

  def set_capability(domain, capability, attributes)
    record(:set_capability, domain, capability, attributes)
    @answers.fetch(:set_capability, { "ok" => true })
  end

  def queue_build(attributes)
    record(:queue_build, attributes)
    @answers.fetch(:queue_build, { "ok" => true, "position" => 1 })
  end

  def preview(domain, path)
    record(:preview, domain, path)
    @answers[:preview]
  end

  def suggest(domain, description)
    record(:suggest, domain, description)
    @answers[:suggest]
  end

  def upload_splash(domain, bytes, background: nil)
    record(:upload_splash, domain, bytes.bytesize, background)
    @answers.fetch(:upload_splash, { "ok" => true })
  end

  def upload_splash_animation(domain, bytes, duration_ms: nil)
    record(:upload_splash_animation, domain, bytes.bytesize, duration_ms)
    @answers.fetch(:upload_splash_animation, { "ok" => true })
  end

  def remove_splash(domain, kind: "image")
    record(:remove_splash, domain, kind)
    @answers.fetch(:remove_splash, { "ok" => true })
  end

  # Every domain this was asked about, in order. The assertion most of these
  # tests actually make.
  def domains_named = @asked.filter_map { |call| call[1] if call[1].is_a?(String) }

  private

  def record(*call) = @asked << call
end

# The menu. Raising is a case of its own: the shell must render without one
# rather than refuse to render at all.
class FakeDirectory
  def initialize(groups: [], raises: nil)
    @groups = groups
    @raises = raises
  end

  def grouped(domain:, only: nil)
    raise @raises if @raises

    @groups
  end
end

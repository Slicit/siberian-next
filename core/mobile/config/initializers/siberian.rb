# frozen_string_literal: true

# Loads the shared library from wherever it is: /app/lib inside a container, or
# ../../lib when running from the monorepo. Explicit require rather than
# autoload, because these files define Siberian::* and Zeitwerk would expect
# names derived from their paths.
shared_lib = [
  Rails.root.join("lib"),
  Rails.root.join("..", "..", "lib")
].find { |path| File.exist?(File.join(path.to_s, "contracts.rb")) }

if shared_lib
  $LOAD_PATH.unshift(File.expand_path(shared_lib.to_s))
  require "contracts"
  require "service_identity"
  require "service_authentication"
  require "served_domains"
else
  Rails.logger&.warn("Shared lib/ not found. Manifest parsing and the engine driver are unavailable.")
end

# Core services address each other by internal DNS short name, so those names
# have to be allowed Hosts. Rails answers an unlisted Host with an HTML error
# page rather than a refusal, which a JSON client happily parses as data: the
# first symptom is not "blocked host" but a bearer token full of markup.
Rails.application.configure do
  # Only ever EXTEND an existing allowlist, never create one. An empty
  # config.hosts means "allow every host", which is what the test environment
  # relies on, and `+=` would quietly turn that into a restrictive list: every
  # integration test then fails with "Blocked hosts: www.example.com".
  if config.hosts.any?
    # "core" is the alias the Router answers to on module networks, so it is the
    # Host every module-originated call arrives with.
    config.hosts += %w[core orchestrator base auth mailer storage database mobile router]

    # Every served domain, asked at request time rather than fixed at boot.
    #
    # The list lives in the Orchestrator database, which this service cannot
    # read, so the Orchestrator publishes it to a file and this consults it. A
    # boot-time list meant a domain added in the Backoffice reached the right
    # server block in the Router and was then refused here until every core
    # service restarted.
    #
    # A callable rather than strings because the answer changes while the
    # process runs. Siberian::ServedDomains caches, so this is not a stat per
    # request, and it merges the environment in so a deployment that has never
    # reconciled behaves exactly as it did before.
    config.hosts << ->(host) { Siberian::ServedDomains.serves?(host) }
  end

  # Health checks come from the engine with whatever Host it feels like using.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end

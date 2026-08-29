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

    # Every served domain, not just one.
    #
    # SIBERIAN_DOMAIN names the first; SIBERIAN_DOMAINS names all of them, comma
    # separated. A second domain used to reach the right server block in the
    # Router and then be refused here, which reads as a routing fault and is
    # not one: the Router had already decided the request was legitimate.
    #
    # Static, so adding a domain in the Backoffice needs a restart before that
    # domain answers. The reconciler reports the gap rather than leaving it to
    # be discovered.
    domains = ENV["SIBERIAN_DOMAINS"].to_s.split(",").map(&:strip).reject(&:empty?)
    domains << ENV["SIBERIAN_DOMAIN"].to_s.strip

    domains.reject(&:empty?).uniq.each do |domain|
      config.hosts << domain
      # Leading dot matches every subdomain, which is how module origins
      # arrive: <module>.apps.<domain>.
      config.hosts << ".#{domain}"
    end
  end

  # Health checks come from the engine with whatever Host it feels like using.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end

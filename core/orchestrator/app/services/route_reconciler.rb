# frozen_string_literal: true

require "openssl"

# Puts routing back the way the database says it should be.
#
# The Router holds two pieces of state the engine owns rather than we do: which
# module networks it is attached to, and which config files are on its volume.
# Replacing the Router container loses the first, because a rebuilt container is
# a new container and its network attachments do not survive. Every module route
# then answers 502 with nothing in any log to explain it.
#
# So this exists, it is idempotent, and it is cheap enough to run whenever
# anything looks wrong.
class RouteReconciler
  Result = Struct.new(:joined, :written, :domains, :reloaded, :errors, keyword_init: true) do
    def ok? = errors.empty?
  end

  def initialize(router: RouterConfig.new, driver: Siberian::Engine.driver)
    @router = router
    @driver = driver
  end

  def call
    domains = Domain.ordered.to_a
    joined = []
    written = []
    errors = []

    InstalledModule.live.find_each do |installed|
      begin
        @router.join_network(installed.network_name)
        joined << installed.network_name

        attach_data_cluster(installed)

        if domains.any?
          @router.write(installed, domains)
          written << installed.name
        end
      rescue StandardError => e
        errors << "#{installed.name}: #{e.message}"
      end
    end

    # The app addresses a module by name, so the map from name to upstream is
    # part of routing being right, not a separate thing to remember.
    @router.refresh_upstreams!(InstalledModule.live)

    # The product shell and the Backoffice, one set per domain.
    #
    # Here rather than in the Router's own start-time template because how many
    # domains exist is a question only this database can answer. Rendered from
    # an environment variable, it served one domain while several were
    # configured, and the ones it missed were answered by the first domain's
    # blocks rather than refused: a wrong answer that looks like a right one.
    written_domains = begin
      @router.write_domains(domains.map(&:hostname))
    rescue StandardError => e
      errors << "domains: #{e.message}"
      []
    end

    # Published for every other service, which cannot read this database and
    # would otherwise refuse a Host it had not been told about at boot.
    begin
      Siberian::ServedDomains.write!(written_domains)
    rescue StandardError => e
      errors << "domains file: #{e.message}"
    end

    # A domain that is served but not in the certificate.
    #
    # Reported rather than repaired, and the distinction matters: reissuing a
    # certificate is `bin/generate-certs`, which needs the CA key and belongs to
    # whoever runs the box, not to a reconcile that a page load can trigger.
    #
    # Without this the failure arrives as a browser warning on one domain while
    # everything else looks healthy, which reads as a browser problem.
    uncertified = written_domains - certified_domains
    if uncertified.any?
      errors << "not in the certificate, so a browser will refuse them: " \
                "#{uncertified.join(', ')}. Reissue with " \
                "SIBERIAN_DOMAINS=#{written_domains.join(',')} FORCE=true bin/generate-certs"
    end

    reloaded = begin
      @router.reload
      true
    rescue StandardError => e
      errors << "reload: #{e.message}"
      false
    end

    Activity.record("routes.reconciled", outcome: errors.empty? ? "succeeded" : "failed",
                                         joined: joined.length, written: written.length,
                                         domains: written_domains.length,
                                         detail: errors.join("; ").presence)

    Result.new(joined: joined, written: written, domains: written_domains,
               reloaded: reloaded, errors: errors)
  end

  private

  # The domains the Router's certificate actually covers, read from the
  # certificate rather than from whatever it was generated with: the file on
  # disk is what a browser will be shown.
  #
  # A wildcard entry certifies the domain it wildcards, because `*.example.test`
  # is what makes `core.example.test` work, and that is what a served domain
  # needs.
  def certified_domains
    path = ENV.fetch("SIBERIAN_CERT_PATH", "/var/lib/siberian/certs/server.pem")
    return [] unless File.exist?(path)

    names = OpenSSL::X509::Certificate.new(File.read(path))
                                      .extensions
                                      .find { |e| e.oid == "subjectAltName" }
                                      &.value.to_s
                                      .split(",")
                                      .filter_map { |entry| entry.strip.delete_prefix("DNS:") }

    names.map { |name| name.sub(/\A\*\./, "") }.uniq
  rescue StandardError => e
    # An unreadable certificate is not a reason to fail a reconcile, and saying
    # nothing about coverage is better than claiming a domain is uncovered
    # because the file could not be parsed.
    Rails.logger.warn("could not read the certificate at #{path}: #{e.message}")
    []
  end

  # The data cluster loses its attachments for the same reason the Router does.
  def attach_data_cluster(installed)
    container = ENV["SIBERIAN_MODULEDB_CONTAINER"].presence
    return if container.nil?

    @driver.attach(container, network: installed.network_name, aliases: ["db"])
  rescue Siberian::Engine::Driver::AlreadyExists
    nil
  rescue StandardError => e
    Rails.logger.warn("could not attach the data cluster to #{installed.network_name}: #{e.message}")
  end
end

# frozen_string_literal: true

require "net/http"

# Asks a freshly installed module whether it serves what its manifest claims.
#
# The manifest is written by somebody else and believed by the core. Nothing
# checked it against the running container, and the cost of that was a mail
# transport: example-relay declared `mail.transport.v1` at `/internal/mail` and
# was a stock nginx image, which cannot serve it. nginx answered 404, a 404 is
# the Mailer being told the message will never be deliverable, and so every
# message in the system died on its first attempt for weeks. Everything reported
# success the whole time, because everything it was asked was answered.
#
# The probe is deliberately weak, and the weakness is the design. It asks
# whether an address exists, not whether it works:
#
#   GET the declared endpoint.
#   404 means nothing is there. That is the failure worth refusing an install
#   over, and the only one this can be sure of.
#   405 means the route exists and does not take GET, which is the correct
#   answer for a transport that only accepts POST, and is a pass.
#
# It must never invoke the capability. A probe that POSTed to a mail transport
# to see whether it was there would send mail, and a probe with side effects is
# a probe nobody dares run.
class ModuleProbe
  Finding = Struct.new(:what, :where, :status, :ok, keyword_init: true) do
    def ok? = ok == true
  end

  # Long enough for a container that has just started and is still opening its
  # database pool, short enough that a module which will never answer does not
  # hold an install open.
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 5

  # A container that has just been started is not serving yet. Rather than one
  # long sleep, ask repeatedly: a module that is ready in 400ms should not cost
  # ten seconds, and one that needs eight should not be failed at five.
  ATTEMPTS = 12
  BETWEEN = 1

  def initialize(installed_module, manifest, domain:,
                 base: ENV.fetch("SIBERIAN_MODULES_URL", "http://modules"),
                 attempts: ATTEMPTS, between: BETWEEN)
    @installed = installed_module
    @manifest = manifest
    @domain = domain
    @base = base
    # Injectable so a test can ask once without waiting. Twelve seconds per
    # missing endpoint is right at install time and wrong in a suite.
    @attempts = attempts
    @between = between
  end

  # Every declared address, checked. Returns findings rather than raising, so
  # the caller decides whether a missing endpoint should fail an install or
  # only be reported.
  def call
    findings = []

    @manifest.system_capabilities.each do |capability|
      endpoint = capability["endpoint"].to_s
      next if endpoint.empty?

      findings << probe("capability #{capability['interface']}", endpoint)
    end

    @manifest.containers.each do |container|
      path = container.dig("health", "path").to_s
      next if path.empty?

      findings << probe("health for #{container['service']}", path)
    end

    findings
  end

  def self.refusal(findings)
    missing = findings.reject(&:ok?)
    return nil if missing.empty?

    detail = missing.map { |f| "#{f.what} at #{f.where} answered #{f.status}" }.join("; ")
    "the module does not serve what its manifest declares: #{detail}"
  end

  private

  # Answers that mean "ask again".
  #
  # Nothing at all, which a container that is still starting gives. 404, which
  # is what the Router says about a module whose upstream map it has not
  # reloaded. And the bad-gateway family, which is what nginx says for the ten
  # seconds its resolver caches the address of a container that has just been
  # replaced.
  #
  # That last one was found by upgrading: the probe accepted a 502 as "the
  # endpoint is there", so a version declaring a path it did not serve upgraded
  # cleanly. A gateway error is the Router saying it cannot reach the module,
  # which is not evidence of anything except that.
  RETRY_ON = %w[000 404 502 503 504].freeze

  def probe(what, path)
    status = nil

    @attempts.times do |attempt|
      status = get(path)
      # Retrying costs a wrong manifest a few seconds at install time and saves
      # an honest module from being refused because nginx was a moment behind.
      # Installs are rare; refusing a correct one is expensive.
      break unless RETRY_ON.include?(status)

      sleep(@between) unless attempt == @attempts - 1
    end

    Finding.new(what: what, where: path, status: status, ok: acceptable?(status))
  end

  # Anything that is not one of the answers above.
  #
  # 405 passes on purpose: a POST-only endpoint is the ordinary shape for a
  # system capability, and refusing those would mean the check could only be
  # satisfied by modules that answer GET to everything.
  #
  # 401 and 403 pass too. An endpoint that refuses an unauthenticated caller is
  # an endpoint that exists, and demanding it be open to this probe would be
  # asking modules to weaken themselves to be installable.
  def acceptable?(status)
    !RETRY_ON.include?(status) && status != "501"
  end
  def get(path)
    uri = URI.join("#{@base}/", "#{@installed.name}/", path.sub(%r{\A/}, ""))
    request = Net::HTTP::Get.new(uri)
    # The Router adds this on the app's door and not on this one, and a module
    # that resolves its database from it answers 500 without it, which reads as
    # a broken module rather than a probe missing a header.
    request["X-Siberian-Domain"] = @domain

    response = Net::HTTP.start(uri.hostname, uri.port,
                               open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.request(request)
    end

    response.code
  rescue StandardError
    "000"
  end
end

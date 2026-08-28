# frozen_string_literal: true

require "net/http"
require "json"

# Puts derived state back the way the database says it should be.
#
# The recurring failure in this system is not a wrong calculation, it is a right
# one that was performed once. Install tells the Mobile service a module exists;
# a module installed before that service did is invisible to it forever. Seeding
# hands a role the catalogue as it stood; a permission added later reaches
# nobody. The Router is told which networks to join; replacing it forgets.
#
# Each of those got its own fix. This is the place the next one goes instead.
#
# Every step is idempotent and reports what it changed, so running this when
# nothing is wrong is free and running it when something is costs one button.
class Reconciler
  # A step reports three different things and they are not interchangeable:
  #
  #   changed  what it put right
  #   drifted  what is wrong and it will not put right by itself
  #   errors   what it could not determine
  #
  # The middle one exists because of the decision recorded in
  # LOGBOOK/features/feat-reconciler.md: repairing a Storage, Database, or
  # Mailer registration issues a token the running container does not have, so
  # a reconciler that "fixed" it would break a working module to mend a broken
  # record. It says so instead.
  Step = Struct.new(:name, :changed, :drifted, :errors, keyword_init: true) do
    def ok? = errors.empty?
    def clean? = ok? && drifted.empty?
  end

  Result = Struct.new(:steps, keyword_init: true) do
    def ok? = steps.all?(&:ok?)
    def clean? = steps.all?(&:clean?)
    def changed = steps.flat_map(&:changed)
    def drifted = steps.flat_map(&:drifted)
    def errors = steps.flat_map(&:errors)
    def step(name) = steps.find { |s| s.name == name }
  end

  # Registrations that hand the module a token it keeps. Reconciling these is
  # reporting only; see the Step comment.
  TOKEN_BEARING = %i[storage database mailer].freeze

  def initialize(registrar: ServiceRegistrar.new,
                 routes: RouteReconciler.new,
                 auth_url: ENV.fetch("SIBERIAN_AUTH_URL", "http://auth:3000"),
                 admin_token: ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only"))
    @registrar = registrar
    @routes = routes
    @auth_url = auth_url
    @admin_token = admin_token
  end

  def call
    steps = [reconcile_routes, reconcile_mobile, inspect_registrations, reconcile_roles]
    result = Result.new(steps: steps)

    Activity.record("state.reconciled",
                    outcome: result.ok? ? "succeeded" : "failed",
                    changed: result.changed.length,
                    drifted: result.drifted.length,
                    detail: summary(result))

    result
  end

  private

  # Delegated rather than absorbed. Routing reconciliation is already tested and
  # already called from two other places; this needs its result, not its code.
  def reconcile_routes
    result = @routes.call
    changed = result.written.map { |name| "route: #{name}" }
    changed << "router reloaded" if result.reloaded

    Step.new(name: :routes, changed: changed, drifted: [], errors: result.errors)
  end

  # The known bug this feature was opened for. Re-sent for every live module
  # rather than only the missing ones, because the payload carries the manifest's
  # current native block: a module whose screens changed on update is as stale
  # to the Mobile service as one it never heard of.
  def reconcile_mobile
    changed = []
    errors = []
    known = begin
      @registrar.known_modules(:mobile)
    rescue StandardError => e
      # Not fatal. Without the list every module is re-sent, which is the
      # correct action anyway and only costs a request each.
      errors << "mobile: could not list registrations: #{e.message}"
      nil
    end

    InstalledModule.live.find_each do |installed|
      @registrar.reregister_mobile(installed, installed.parsed_manifest)
      changed << "mobile: #{installed.name}" if known.nil? || !known.include?(installed.name)
    rescue StandardError => e
      errors << "mobile: #{installed.name}: #{e.message}"
    end

    Step.new(name: :mobile, changed: changed, drifted: [], errors: errors)
  end

  # Compares and reports. A module named here is one whose containers hold a
  # token the service has no digest for, so every call it makes to that service
  # is being refused. The repair is a reinstall, which recreates the container
  # around a token that was issued to it.
  def inspect_registrations
    drifted = []
    errors = []
    live = InstalledModule.live.to_a

    TOKEN_BEARING.each do |service|
      known = begin
        @registrar.known_modules(service)
      rescue StandardError => e
        errors << "#{service}: could not list registrations: #{e.message}"
        next
      end

      live.each do |installed|
        next unless expects_registration?(installed, service)
        next if known.include?(installed.name)

        drifted << "#{service}: #{installed.name} is not registered, reinstall it to reissue its token"
      end
    end

    Step.new(name: :registrations, changed: [], drifted: drifted, errors: errors)
  end

  # A module only holds a token for a service its manifest asked for. Reporting
  # a missing Mailer registration for a module that never asked to send mail
  # would be noise that trains an operator to ignore the list.
  def expects_registration?(installed, service)
    manifest = installed.parsed_manifest

    case service
    when :storage then manifest.storage_spaces.any?
    when :database then manifest.database_grants.any?
    when :mailer then manifest.mail_grant.present? && manifest.mail_grant["send"]
    else false
    end
  rescue StandardError
    # An unparseable stored manifest is its own problem and not this step's to
    # report. Assuming it expects nothing keeps this list about registrations.
    false
  end

  def reconcile_roles
    body = auth_post("/internal/roles/reconcile")
    changed = Hash(body["added"]).flat_map do |role, permissions|
      Array(permissions).map { |permission| "role #{role}: #{permission}" }
    end

    Step.new(name: :roles, changed: changed, drifted: [], errors: [])
  rescue StandardError => e
    Step.new(name: :roles, changed: [], drifted: [], errors: ["roles: #{e.message}"])
  end

  def auth_post(path)
    uri = URI.join(@auth_url, path)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@admin_token}"
    request["Content-Type"] = "application/json"
    request.body = "{}"

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 15) do |http|
      http.request(request)
    end

    unless response.code.to_i.between?(200, 299)
      raise "#{uri} returned #{response.code}: #{response.body.to_s[0, 200]}"
    end

    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  end

  def summary(result)
    parts = result.steps.map do |step|
      "#{step.name}: #{step.changed.length} changed, #{step.drifted.length} drifted, #{step.errors.length} errors"
    end
    parts.join("; ")
  end
end

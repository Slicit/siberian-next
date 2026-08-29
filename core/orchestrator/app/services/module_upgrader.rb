# frozen_string_literal: true

# Moves an installed module to a new version of its manifest.
#
# Before this, upgrading meant uninstalling and installing again by hand. That
# works and is worse than it sounds: it revokes the module's credentials,
# detaches its network, drops its containers, and gives it a new uuid, all of
# which is fine right up until one of those steps fails and there is no module
# left. It also gives an operator no way back if the new version is broken.
#
# This keeps everything that identifies the module (its uuid, its network, its
# databases, its buckets) and replaces only what the manifest changed. When the
# new version does not come up, the old containers are put back from the images
# they were running, so a failed upgrade leaves the working version running
# rather than nothing at all.
class ModuleUpgrader
  Result = Struct.new(:success, :installed_module, :error, :changed, :warnings, keyword_init: true) do
    def success? = success == true
    def changed? = changed == true
  end

  class WrongModule < StandardError; end

  def initialize(installed_module, manifest,
                 driver: Siberian::Engine.driver,
                 router: RouterConfig.new,
                 registrar: nil,
                 domains: nil,
                 probe: ModuleProbe)
    @installed = installed_module
    @manifest = manifest
    @driver = driver
    @router = router
    @registrar = registrar
    @domains = domains
    @probe = probe
    @warnings = []
  end

  def call
    @manifest.validate!

    unless @manifest.name == @installed.name
      raise WrongModule, "that manifest is for #{@manifest.name}, not #{@installed.name}"
    end

    # Nothing to do, said out loud. Rebuilding an image under the same tag and
    # calling this changes nothing that is running, and an operator who is not
    # told that will spend a while wondering why their fix did not take. That
    # exact confusion cost an afternoon.
    if unchanged?
      return Result.new(success: true, installed_module: @installed, changed: false,
                        error: "#{@installed.name} is already at #{@manifest.version} " \
                               "with the same images. Nothing to replace.",
                        warnings: [])
    end

    previous = snapshot
    Activity.record("upgrade.started", installed_module: @installed,
                    from: @installed.version, to: @manifest.version)

    begin
      replace_containers
      republish_routes
      verify_declarations

      @installed.update!(version: @manifest.version, manifest: @manifest.data,
                         status: @installed.derived_status, last_error: nil)
      Activity.record("upgrade.finished", installed_module: @installed, version: @manifest.version)

      Result.new(success: true, installed_module: @installed, changed: true, warnings: @warnings)
    rescue StandardError => e
      restore(previous)
      @installed.update(last_error: e.message, status: @installed.derived_status)
      Activity.record("upgrade.rolled_back", installed_module: @installed,
                      outcome: "failed", detail: e.message)

      Result.new(success: false, installed_module: @installed, changed: false,
                 error: "#{e.message}. The previous version has been put back.",
                 warnings: @warnings)
    end
  end

  private

  def domains
    @resolved_domains ||= @domains || Domain.ordered.to_a
  end

  # Version and images together, not version alone. A manifest can move its
  # version without moving an image, and an image tag can move without the
  # version, and only one of those is worth restarting containers over.
  def unchanged?
    return false if @installed.version != @manifest.version

    current = @installed.module_containers.order(:service).pluck(:service, :image)
    wanted = @manifest.container_specs(uuid: @installed.uuid)
                      .map { |spec| [spec.labels["siberian.service"], spec.image] }.sort

    current == wanted
  end

  # Enough to put the old version back: what was running, and where.
  def snapshot
    @installed.module_containers.map do |container|
      {
        service: container.service, name: container.name, image: container.image,
        role: container.role, internal_port: container.internal_port,
        engine_id: container.engine_id
      }
    end
  end

  def replace_containers
    # Removed before the new ones are created, because they hold the container
    # names: two containers cannot share one, and the name is derived from the
    # uuid and the service, both of which are being kept on purpose.
    @installed.module_containers.each do |container|
      attempt("remove #{container.name}") { @driver.remove(container.engine_id, force: true) }
      container.destroy!
    end

    tokens = @registrar ? @registrar.register(@installed, @manifest) : nil
    extra_env = core_environment(tokens)

    @manifest.container_specs(uuid: @installed.uuid).each do |spec|
      spec.env = extra_env.merge(spec.env || {})

      container = @installed.module_containers.create!(
        service: spec.labels["siberian.service"], name: spec.name, image: spec.image,
        role: spec.role.to_s, internal_port: spec.internal_port
      )

      engine_id = @driver.create(spec, network: @installed.network_name)
      @driver.start(engine_id)
      container.update!(engine_id: engine_id, state: @driver.status(engine_id).to_s,
                        state_checked_at: Time.current)
    end
  end

  # The port can change between versions, and the upstream map is where that
  # lives. A version that moved from 80 to 8080 and did not republish would
  # answer every request with a 502.
  def republish_routes
    return if domains.empty?

    @router.write(@installed, domains)
    @router.refresh_upstreams!(InstalledModule.live.where.not(id: @installed.id).to_a + [@installed])
    @router.reload
  end

  def verify_declarations
    return if domains.empty?
    return if @manifest.system_capabilities.empty? && @manifest.containers.none? { |c| c["health"] }

    findings = @probe.new(@installed, @manifest, domain: domains.first.hostname).call
    refusal = @probe.refusal(findings)

    raise ModuleInstaller::Dishonest, refusal if refusal
  end

  # The whole point of taking a snapshot. A failed upgrade must leave the
  # version that was working running, not an empty network.
  def restore(previous)
    @installed.module_containers.each do |container|
      attempt("remove the failed #{container.name}") { @driver.remove(container.engine_id, force: true) }
      container.destroy!
    end

    tokens = @registrar ? @registrar.register(@installed, previous_manifest) : nil
    extra_env = core_environment(tokens)

    previous_manifest.container_specs(uuid: @installed.uuid).each do |spec|
      spec.env = extra_env.merge(spec.env || {})

      container = @installed.module_containers.create!(
        service: spec.labels["siberian.service"], name: spec.name, image: spec.image,
        role: spec.role.to_s, internal_port: spec.internal_port
      )

      attempt("put back #{spec.name}") do
        engine_id = @driver.create(spec, network: @installed.network_name)
        @driver.start(engine_id)
        container.update!(engine_id: engine_id, state: @driver.status(engine_id).to_s,
                          state_checked_at: Time.current)
      end
    end

    attempt("restore routing") do
      @router.write(@installed, domains)
      @router.refresh_upstreams!(InstalledModule.live.to_a)
      @router.reload
    end
  end

  # The manifest as it was recorded at install, which is the one the containers
  # being put back were built from.
  def previous_manifest
    @previous_manifest ||= Siberian::Contracts::Manifest.new(@installed.manifest)
  end

  # The same environment the installer injects. Shared rather than copied: a
  # module that came up on install and not on upgrade because one of these was
  # missing would be a very quiet bug.
  def core_environment(tokens)
    env = {
      "SIBERIAN_CORE_URL" => "http://core",
      "SIBERIAN_AUTH_URL" => "http://core/auth",
      "SIBERIAN_STORAGE_URL" => "http://core/storage",
      "SIBERIAN_DATABASE_URL" => "http://core/database",
      "SIBERIAN_MAILER_URL" => "http://core/mailer"
    }
    env["SIBERIAN_STORAGE_TOKEN"] = tokens&.storage_token if tokens&.storage_token
    env["SIBERIAN_DATABASE_TOKEN"] = tokens&.database_token if tokens&.database_token
    env["SIBERIAN_MAIL_TOKEN"] = tokens&.mail_token if tokens&.mail_token
    env
  end
  # Best effort during a rollback: something the engine has already lost must
  # not stop the rest of the old version coming back.
  def attempt(description)
    yield
  rescue StandardError => e
    @warnings << "#{description}: #{e.message}"
  end
end

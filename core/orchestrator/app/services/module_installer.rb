# frozen_string_literal: true

# Installs a module: record, network, containers, routing.
#
# Every step that creates something outside the database registers how to undo
# itself. A module that fails halfway through installation is worse than one
# that never installed, because the operator cannot see what is left behind.
class ModuleInstaller
  Result = Struct.new(:success, :installed_module, :error, keyword_init: true) do
    def success? = success == true
  end

  class AlreadyInstalled < StandardError; end
  class ConflictingInterface < StandardError; end
  # The manifest said the module serves something it does not.
  class Dishonest < StandardError; end

  def initialize(manifest,
                 driver: Siberian::Engine.driver,
                 router: RouterConfig.new,
                 registrar: nil,
                 domains: nil)
    @manifest = manifest
    @driver = driver
    @router = router
    # Injected rather than reached for, so installation can be tested without a
    # Storage service and a Database service standing behind it.
    @registrar = registrar
    @domains = domains
    @undo = []
  end

  def call
    @manifest.validate!
    raise AlreadyInstalled, "#{@manifest.name} is already installed" if InstalledModule.exists?(name: @manifest.name)

    check_interface_conflicts!

    installed = create_record
    Activity.record("install.started", installed_module: installed, outcome: "started", module_name: @manifest.name)

    # Before the containers, because the tokens these calls return are injected
    # into them as environment. A module that has to fetch credentials from a
    # service it was never introduced to cannot start.
    tokens = register_with_services(installed)

    create_network(installed)
    attach_data_cluster(installed)
    create_containers(installed, tokens)
    provision(installed)
    publish_routes(installed)
    verify_declarations(installed)

    installed.update!(status: installed.derived_status, installed_at: Time.current, last_error: nil)
    Activity.record("install.finished", installed_module: installed, containers: installed.module_containers.count)

    Result.new(success: true, installed_module: installed)
  rescue StandardError => e
    roll_back
    record_failure(e)
    Result.new(success: false, installed_module: @installed, error: e.message)
  end

  private

  def domains
    @domains ||= Domain.ordered.to_a
  end

  def create_record
    @installed = InstalledModule.create!(
      uuid: SecureRandom.uuid.delete("-")[0, 12],
      name: @manifest.name,
      version: @manifest.version,
      title: @manifest.title,
      description: @manifest.description,
      status: "installing",
      base_route: @manifest.base_route,
      origin: @manifest.origin,
      entry_service: @manifest.routes["entry"],
      manifest: @manifest.data
    )

    @installed.update!(network_name: @manifest.network_name(@installed.uuid))
    persist_grants(@installed)
    persist_capabilities(@installed)
    @installed
  end

  def persist_grants(installed)
    @manifest.database_grants.each do |grant|
      installed.grants.create!(
        kind: "database",
        target: grant["name"] || grant["target"],
        access: grant["access"],
        scope: grant["scope"] || "per_domain",
        details: { "provisioned" => grant.key?("name") },
        approved_at: Time.current
      )
    end

    if @manifest.storage_spaces.any?
      installed.grants.create!(
        kind: "storage",
        access: "owner",
        scope: "per_domain",
        details: {
          "spaces" => @manifest.storage_spaces,
          "quota_mb" => @manifest.storage_grant["quota_mb"] || 512
        },
        approved_at: Time.current
      )
    end

    if @manifest.mail_grant && @manifest.mail_grant["send"]
      installed.grants.create!(kind: "mail", access: "send", scope: "global", approved_at: Time.current)
    end

    @manifest.module_grants.each do |grant|
      installed.grants.create!(
        kind: "module",
        target: grant["name"],
        access: grant["access"],
        scope: "global",
        details: { "optional" => grant.fetch("optional", false) },
        approved_at: Time.current
      )
    end
  end

  def persist_capabilities(installed)
    @manifest.system_capabilities.each_with_index do |capability, index|
      installed.capabilities.create!(
        kind: "system",
        capability_id: capability["id"],
        interface: capability["interface"],
        endpoint: capability["endpoint"],
        title: capability["title"] || capability["interface"],
        priority: capability["priority"] || 100,
        exclusive: capability.fetch("exclusive", false),
        position: index
      )
    end

    @manifest.feature_capabilities.each_with_index do |capability, index|
      installed.capabilities.create!(
        kind: "feature",
        capability_id: capability["id"],
        area: capability["area"],
        title: capability["title"],
        path: capability["path"],
        icon: capability["icon"],
        accepts: capability["accepts"] || [],
        position: capability["position"] || index
      )
    end

    @manifest.consumed_capabilities.each do |capability|
      installed.capability_requests.create!(
        capability_id: capability["id"],
        optional: capability.fetch("optional", true)
      )
    end
  end

  # Two modules claiming the same interface exclusively is a conflict an
  # operator has to resolve. Deciding it silently at install time means the core
  # starts routing mail somewhere nobody chose.
  def check_interface_conflicts!
    @manifest.system_capabilities.each do |capability|
      next unless capability.fetch("exclusive", false)

      existing = Capability.exclusive_conflict_for(capability["interface"])
      next if existing.nil?

      raise ConflictingInterface,
            "#{existing.installed_module.name} already claims #{capability['interface']} exclusively"
    end

    @manifest.provided_capabilities.each do |capability|
      taken = Capability.find_by(capability_id: capability["id"])
      next if taken.nil?

      raise ConflictingInterface,
            "capability #{capability['id']} is already provided by #{taken.installed_module.name}"
    end
  end

  def create_network(installed)
    @driver.create_network(installed.network_name)
    @undo << -> { @driver.remove_network(installed.network_name) }
    Activity.record("network.created", installed_module: installed, network: installed.network_name)
  rescue Siberian::Engine::Driver::AlreadyExists
    # A leftover network from a failed install is reusable; a leftover container
    # is not, which is why only this one is tolerated.
    Activity.record("network.reused", installed_module: installed, network: installed.network_name)
  end

  # Everything a module needs to find the core, handed to it rather than
  # discovered. The addresses are the Router aliases, so a module never learns
  # a container name.
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

  def register_with_services(installed)
    return nil if @registrar.nil?

    tokens = @registrar.register(installed, @manifest)
    @undo << -> { @registrar.revoke(installed) }

    approved = @registrar.approve_table_grants(installed, @manifest)
    if approved.any?
      Activity.record("grants.approved", installed_module: installed, grants: approved)
    end

    tokens
  end

  # The module data cluster answers to "db" on every module network. A module
  # connects to Postgres directly with the credentials the Database service
  # issued it; nothing proxies a module reading its own data.
  def attach_data_cluster(installed)
    container = ENV["SIBERIAN_MODULEDB_CONTAINER"].presence
    return if container.nil?

    @driver.attach(container, network: installed.network_name, aliases: ["db"])
    @undo << -> { @driver.detach(container, network: installed.network_name) }
    Activity.record("data_cluster.attached", installed_module: installed, network: installed.network_name)
  rescue Siberian::Engine::Driver::AlreadyExists
    nil
  rescue StandardError => e
    # A module with no database grant does not need the cluster, so this is a
    # warning rather than a failed install.
    Activity.record("data_cluster.attach_failed", installed_module: installed,
                                                  outcome: "failed", detail: e.message)
  end

  def create_containers(installed, tokens = nil)
    extra_env = core_environment(tokens)

    @manifest.container_specs(uuid: installed.uuid).each do |spec|
      spec.env = extra_env.merge(spec.env || {})
      container = installed.module_containers.create!(
        service: spec.labels["siberian.service"],
        name: spec.name,
        image: spec.image,
        role: spec.role.to_s,
        internal_port: spec.internal_port
      )

      engine_id = @driver.create(spec, network: installed.network_name)
      @undo << -> { @driver.remove(engine_id, force: true) }

      @driver.start(engine_id)
      container.update!(engine_id: engine_id, state: @driver.status(engine_id).to_s, state_checked_at: Time.current)

      Activity.record("container.created", installed_module: installed, container: spec.name, image: spec.image)
    end
  end

  # Per (module, domain), because that is where isolation lives. The containers
  # exist once and are shared across every domain.
  def provision(installed)
    return if @registrar.nil?

    domains.each do |domain|
      @registrar.provision(installed, @manifest, domain).each do |provision|
        installed.provisions.create!(
          domain: domain,
          kind: provision[:kind],
          identifier: provision[:identifier],
          state: "ready"
        )
        Activity.record("provisioned", installed_module: installed, kind: provision[:kind],
                                       domain: domain.hostname, identifier: provision[:identifier])
      end
    end
  end

  def publish_routes(installed)
    return if domains.empty?

    @router.join_network(installed.network_name)
    @undo << -> { @router.leave_network(installed.network_name) }

    @router.write(installed, domains)
    @undo << -> { @router.remove(installed) }
    # `live` is running or degraded, and this module is still `installing`, so
    # it would be the one module missing from its own upstream map: installed,
    # routed on its own origin, and unreachable at /m/<name>/ until something
    # else reconciled routing.
    @router.refresh_upstreams!(InstalledModule.live.where.not(id: installed.id).to_a + [installed])
    @router.reload
    Activity.record("routes.published", installed_module: installed, domains: domains.map(&:hostname))
  end


  # The last thing before an install is called a success: does the module
  # actually serve what it said it would?
  #
  # After the routes, because the probe reaches the module the way the core
  # will. Before the record is marked installed, because the point is to refuse
  # rather than to report: an install that half succeeded leaves an operator
  # with a module in the list that no part of the system can use, and the mail
  # transport that spent weeks answering 404 is what that looks like.
  #
  # Skipped when there is nowhere to reach it from. A stack with no domains has
  # no module door, and refusing every install on that basis would make the
  # first domain impossible to set up.
  def verify_declarations(installed)
    return if domains.empty?
    return if @manifest.system_capabilities.empty? && @manifest.containers.none? { |c| c["health"] }

    findings = ModuleProbe.new(installed, @manifest, domain: domains.first.hostname).call
    refusal = ModuleProbe.refusal(findings)

    Activity.record("install.probed", installed_module: installed,
                    checked: findings.length, failed: findings.count { |f| !f.ok? })

    raise Dishonest, refusal if refusal
  end
  # Undone in reverse, so a container is removed before the network it sits on.
  def roll_back
    @undo.reverse_each do |step|
      step.call
    rescue StandardError => e
      Rails.logger.error("rollback step failed: #{e.message}")
    end
    @undo.clear
  end

  def record_failure(error)
    if @installed&.persisted?
      @installed.update(status: "failed", last_error: error.message)
      Activity.record("install.failed", installed_module: @installed, outcome: "failed", detail: error.message)
      # The record is kept, not deleted: an operator needs to see what failed
      # and why, and a row is the only thing that survives to tell them.
    else
      Activity.record("install.failed", outcome: "failed", detail: error.message, module_name: @manifest.name)
    end
  end
end

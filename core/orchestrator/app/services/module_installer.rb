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

  def initialize(manifest,
                 driver: Siberian::Engine.driver,
                 router: RouterConfig.new,
                 provisioners: self.class.default_provisioners,
                 domains: nil)
    @manifest = manifest
    @driver = driver
    @router = router
    @provisioners = Array(provisioners)
    @domains = domains
    @undo = []
  end

  # Provisioners run once per (module, domain) pair. They are injected rather
  # than reached for, so installation can be tested without a Database service
  # and a Storage service standing behind it.
  def self.default_provisioners
    []
  end

  def call
    @manifest.validate!
    raise AlreadyInstalled, "#{@manifest.name} is already installed" if InstalledModule.exists?(name: @manifest.name)

    installed = create_record
    Activity.record("install.started", installed_module: installed, outcome: "started", module_name: @manifest.name)

    create_network(installed)
    create_containers(installed)
    provision(installed)
    publish_routes(installed)

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
    @manifest.provided_capabilities.each_with_index do |capability, index|
      installed.capabilities.create!(
        capability_id: capability["id"],
        area: capability["area"],
        title: capability["title"],
        path: capability["path"],
        icon: capability["icon"],
        accepts: capability["accepts"] || [],
        position: index
      )
    end

    @manifest.consumed_capabilities.each do |capability|
      installed.capability_requests.create!(
        capability_id: capability["id"],
        optional: capability.fetch("optional", true)
      )
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

  def create_containers(installed)
    @manifest.container_specs(uuid: installed.uuid).each do |spec|
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

  def provision(installed)
    return if @provisioners.empty?

    domains.each do |domain|
      @provisioners.each do |provisioner|
        next unless provisioner.applies_to?(installed)

        provision = provisioner.call(installed, domain)
        next if provision.nil?

        @undo << -> { provisioner.undo(installed, domain) }
        Activity.record("provisioned", installed_module: installed, kind: provision.kind,
                                       domain: domain.hostname, identifier: provision.identifier)
      end
    end
  end

  def publish_routes(installed)
    return if domains.empty?

    @router.join_network(installed.network_name)
    @undo << -> { @router.leave_network(installed.network_name) }

    @router.write(installed, domains)
    @undo << -> { @router.remove(installed) }
    @router.reload
    Activity.record("routes.published", installed_module: installed, domains: domains.map(&:hostname))
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

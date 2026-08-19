# frozen_string_literal: true

require "test_helper"
require "support/fake_engine"

class ModuleInstallerTest < ActiveSupport::TestCase
  setup do
    @engine = FakeEngine.new
    @router = FakeRouter.new
    @domain = Domain.create!(hostname: "example.test", primary: true)
  end

  def manifest(yaml = nil)
    Siberian::Contracts::Manifest.parse(yaml || <<~YAML)
      schema_version: 1
      name: demo-tasks
      version: 1.0.0
      title: Demo Tasks
      containers:
        - service: web
          image: nginx:1.27-alpine
          role: http
          internal_port: 80
        - service: cache
          image: redis:7-alpine
          role: datastore
      routes:
        base: /demo-tasks
        entry: web
      permissions:
        databases:
          - name: primary
            access: owner
            scope: per_domain
        storage:
          spaces: [files, public]
          quota_mb: 128
        mail:
          send: true
      capabilities:
        features:
          - id: demo_tasks.task.viewer
            area: sidebar.entities
            title: Tasks
            path: /tasks
        system:
          - id: demo_tasks.cache.store
            interface: cache.store.v1
            endpoint: /internal/cache
            title: Demo cache
        consumes:
          - id: core.user.picker
    YAML
  end

  def install(manifest_object = nil)
    ModuleInstaller.new(
      manifest_object || manifest,
      driver: @engine,
      router: @router,
      domains: [@domain]
    ).call
  end

  # The happy path -------------------------------------------------------

  test "installing records the module and everything it declared" do
    result = install

    assert result.success?, result.error
    installed = result.installed_module

    assert_equal "demo-tasks", installed.name
    assert_equal "running", installed.status
    assert_equal 2, installed.module_containers.count
    assert_equal 2, installed.capabilities.count
    assert_equal 1, installed.capabilities.features.count
    assert_equal 1, installed.capabilities.system.count
    assert_equal 1, installed.capability_requests.count
    assert_equal 3, installed.grants.count
    assert installed.installed_at.present?
  end

  test "every container is created on the module's own network and started" do
    installed = install.installed_module

    assert_equal ["siberian-mod-#{installed.uuid}"], @engine.networks
    assert_equal 2, @engine.containers.size
    assert @engine.containers.values.all? { |c| c[:state] == :running }
    assert @engine.containers.values.all? { |c| c[:network] == installed.network_name }
  end

  test "container names carry the uuid so two installs never collide" do
    installed = install.installed_module

    assert_includes @engine.container_names, "#{installed.uuid}-demo-tasks-web"
    assert_includes @engine.container_names, "#{installed.uuid}-demo-tasks-cache"
  end

  test "routes are written and the router is reloaded" do
    install

    assert_equal ["example.test"], @router.written["demo-tasks"]
    assert_equal 1, @router.reloads, "a write nginx was never told about is invisible"
  end

  test "the router joins the module network, or every route is a 502" do
    installed = install.installed_module

    assert_includes @router.joined_networks, installed.network_name,
                    "the router sits on the core network; without joining, the module short name resolves to nothing"
  end

  test "grants record what the operator approved, not what the module asked for" do
    installed = install.installed_module

    database = installed.grants.find_by(kind: "database")
    assert_equal "owner", database.access
    assert_equal "per_domain", database.scope
    assert database.approved?

    storage = installed.grants.find_by(kind: "storage")
    assert_equal %w[files public], storage.details["spaces"]
    assert_equal 128, storage.details["quota_mb"]
  end

  test "installing twice is refused rather than producing a second copy" do
    install

    result = install

    refute result.success?
    assert_match(/already installed/, result.error)
    assert_equal 1, InstalledModule.count
  end

  test "a system capability is registered against its interface" do
    installed = install.installed_module

    capability = installed.capabilities.system.first
    assert_equal "cache.store.v1", capability.interface
    assert_equal "http://demo-tasks/internal/cache", capability.internal_url
  end

  test "two modules claiming one interface exclusively is refused" do
    exclusive = <<~YAML
      schema_version: 1
      name: first-relay
      version: 1.0.0
      title: First
      containers:
        - service: web
          image: nginx:1.27-alpine
          role: http
          internal_port: 80
      routes:
        base: /first-relay
        entry: web
      capabilities:
        system:
          - id: first_relay.mail.transport
            interface: mail.transport.v1
            endpoint: /internal/mail
            exclusive: true
    YAML
    assert install(Siberian::Contracts::Manifest.parse(exclusive)).success?

    second = exclusive.sub("first-relay", "second-relay").sub("first_relay", "second_relay").sub("/first-relay", "/second-relay")
    result = install(Siberian::Contracts::Manifest.parse(second))

    refute result.success?
    assert_match(/already claims mail.transport.v1/, result.error)
  end

  test "a capability id already provided elsewhere is refused" do
    install

    clash = Siberian::Contracts::Manifest.parse(<<~YAML)
      schema_version: 1
      name: other-module
      version: 1.0.0
      title: Other
      containers:
        - service: web
          image: nginx:1.27-alpine
          role: http
          internal_port: 80
      routes:
        base: /other-module
        entry: web
      capabilities:
        features:
          - id: demo_tasks.task.viewer
            area: sidebar.entities
            title: Clash
            path: /clash
    YAML

    result = install(clash)

    refute result.success?
    assert_match(/already provided by demo-tasks/, result.error)
  end

  # Failure and rollback -------------------------------------------------

  test "a container that cannot start leaves nothing behind" do
    engine = FakeEngine.new(fail_on: :start)

    result = ModuleInstaller.new(manifest, driver: engine, router: @router, domains: [@domain]).call

    refute result.success?
    assert_empty engine.containers, "a failed install must not leave containers running"
    assert_empty engine.networks, "a failed install must not leave a network behind"
  end

  test "a failed install keeps the record so an operator can see what happened" do
    engine = FakeEngine.new(fail_on: :start)

    ModuleInstaller.new(manifest, driver: engine, router: @router, domains: [@domain]).call

    installed = InstalledModule.find_by(name: "demo-tasks")
    assert_equal "failed", installed.status
    assert installed.last_error.present?
  end

  test "a router that refuses to reload rolls the install back" do
    router = FakeRouter.new(fail_reload: true)

    result = ModuleInstaller.new(manifest, driver: @engine, router: router, domains: [@domain]).call

    refute result.success?
    assert_empty @engine.containers
    assert_includes router.removed, "demo-tasks"
  end

  test "an invalid manifest is refused before anything is created" do
    broken = Siberian::Contracts::Manifest.parse(<<~YAML)
      name: broken
      version: 1.0.0
      containers:
        - service: web
          image: nginx
          role: worker
      routes:
        base: /broken
        entry: web
    YAML

    result = install(broken)

    refute result.success?
    assert_equal 0, InstalledModule.count
    assert_empty @engine.networks
  end

  # The activity log -----------------------------------------------------

  test "each step of an install is recorded" do
    install

    actions = Activity.order(:id).pluck(:action)
    assert_includes actions, "install.started"
    assert_includes actions, "network.created"
    assert_includes actions, "container.created"
    assert_includes actions, "routes.published"
    assert_includes actions, "install.finished"
  end

  test "a failure is recorded with the reason" do
    engine = FakeEngine.new(fail_on: :create)

    ModuleInstaller.new(manifest, driver: engine, router: @router, domains: [@domain]).call

    failure = Activity.find_by(action: "install.failed")
    assert failure.present?
    assert_equal "failed", failure.outcome
    assert_match(/engine refused/, failure.detail)
  end
end

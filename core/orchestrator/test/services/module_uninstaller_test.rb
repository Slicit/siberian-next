# frozen_string_literal: true

require "test_helper"
require "support/fake_engine"

class ModuleUninstallerTest < ActiveSupport::TestCase
  setup do
    @engine = FakeEngine.new
    @router = FakeRouter.new
    @domain = Domain.create!(hostname: "example.test", primary: true)
    @installed = ModuleInstaller.new(manifest, driver: @engine, router: @router, domains: [@domain])
                               .call.installed_module
  end

  def manifest
    Siberian::Contracts::Manifest.parse(<<~YAML)
      schema_version: 1
      name: demo-tasks
      version: 1.0.0
      title: Demo Tasks
      containers:
        - service: web
          image: nginx:1.27-alpine
          role: http
          internal_port: 80
      routes:
        base: /demo-tasks
        entry: web
    YAML
  end

  def uninstall(**options)
    ModuleUninstaller.new(@installed, driver: @engine, router: @router, **options).call
  end

  test "uninstalling removes the record, the containers, and the network" do
    result = uninstall

    assert result.success?, result.error
    assert_equal 0, InstalledModule.count
    assert_empty @engine.containers
    assert_empty @engine.networks
  end

  test "the route is withdrawn before the containers are removed" do
    uninstall

    assert_includes @router.removed, "demo-tasks"
    refute @router.written.key?("demo-tasks")
  end

  test "the router leaves the module network before it is removed" do
    network = @installed.network_name

    uninstall

    assert_includes @router.left_networks, network
  end

  # The Router is not the only thing on a module network. RouteReconciler also
  # joins the module data cluster to every one, and nothing used to take it off.
  # A network with anything still attached cannot be removed, the failure was
  # swallowed, and every uninstall left one behind until Docker ran out of
  # address pools and no module could be installed at all.
  test "the data cluster leaves the module network too, so the network can go" do
    network = @installed.network_name
    ENV["SIBERIAN_MODULEDB_CONTAINER"] = "siberian-moduledb-1"
    @engine.attach("siberian-moduledb-1", network: network, aliases: ["db"])

    result = uninstall

    assert result.success?, result.error
    assert_empty @engine.attached_to(network),
                 "anything left attached is what stops the network being removed"
    refute_includes @engine.networks, network
  ensure
    ENV.delete("SIBERIAN_MODULEDB_CONTAINER")
  end

  test "a container the engine has already lost does not block removal" do
    @engine.containers.clear

    result = uninstall

    assert result.success?, result.error
    assert_equal 0, InstalledModule.count
  end

  test "removing a module leaves its data alone unless asked otherwise" do
    result = uninstall

    assert result.success?
    # Nothing released: reinstalling a module and finding its files gone is a
    # worse surprise than a bucket left behind.
    assert_empty result.warnings
  end

  test "uninstalling is recorded" do
    uninstall

    actions = Activity.order(:id).pluck(:action)
    assert_includes actions, "uninstall.started"
    assert_includes actions, "uninstall.finished"
  end
end

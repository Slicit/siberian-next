# frozen_string_literal: true

require "test_helper"
require "support/fake_engine"
require "tmpdir"

class RouterConfigTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("router-config")
    @engine = FakeEngine.new
    @router = RouterConfig.new(driver: @engine, config_dir: @dir, router_container: "router-1")
    @domain = Domain.create!(hostname: "example.test", primary: true)
    @installed = InstalledModule.create!(
      uuid: "abc123", name: "demo-tasks", version: "1.0.0", title: "Demo Tasks",
      status: "running", origin: "demo-tasks", entry_service: "web",
      network_name: "siberian-mod-abc123"
    )
    @installed.module_containers.create!(service: "web", name: "abc123-demo-tasks-web",
                                        image: "nginx", role: "http", internal_port: 80)
  end

  teardown { FileUtils.remove_entry(@dir) if File.directory?(@dir) }

  test "the rendered config carries no unsubstituted placeholders" do
    body = @router.write(@installed, [@domain])

    refute_includes body, "${", "an unsubstituted placeholder is a config nginx cannot parse"
  end

  test "the template's own explanation of its placeholders does not travel" do
    body = @router.write(@installed, [@domain])

    refute_includes body, "Substitutions:", "rendering the header turns the explanation into nonsense"
    assert body.lstrip.start_with?("server {"), "the rendered file should begin with the server block"
  end

  test "the module is served at its own origin" do
    body = @router.write(@installed, [@domain])

    assert_includes body, "server_name demo-tasks.apps.example.test;"
  end

  test "frame-ancestors names the parent domain, so only the Base App may frame it" do
    body = @router.write(@installed, [@domain])

    assert_includes body, "frame-ancestors https://example.test"
  end

  test "the upstream is the module short name, never the uuid-prefixed container" do
    body = @router.write(@installed, [@domain])

    assert_includes body, "http://demo-tasks:80"
    refute_includes body, "abc123-demo-tasks-web"
  end

  test "one server block per domain" do
    second = Domain.create!(hostname: "other.test")

    body = @router.write(@installed, [@domain, second])

    assert_equal 2, body.scan("server {").length
  end

  test "removing a module unlinks only its own file" do
    @router.write(@installed, [@domain])
    assert File.exist?(@router.path_for(@installed))

    @router.remove(@installed)

    refute File.exist?(@router.path_for(@installed))
  end

  test "a reload that nginx rejects is raised, not swallowed" do
    engine = Class.new(FakeEngine) do
      def exec_in(_id, _command, detach: false) = "nginx: [emerg] unknown directive"
    end.new
    router = RouterConfig.new(driver: engine, config_dir: @dir, router_container: "router-1")

    assert_raises(RouterConfig::ReloadFailed) { router.reload }
  end
end

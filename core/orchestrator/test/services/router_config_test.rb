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

  # --- per-domain core blocks -------------------------------------------------
  #
  # These used to be rendered once at Router start from a single environment
  # variable, so the Router served one domain while the database held several.
  # The domains it missed were not refused: they fell through to the first
  # matching server block and were answered as the wrong domain.

  def domain_file(hostname) = File.join(@dir, RouterConfig::DOMAINS_DIR, "#{hostname}.conf")

  test "every served domain gets its own core blocks" do
    @router.write_domains(%w[first.test second.test])

    %w[first.test second.test].each do |hostname|
      body = File.read(domain_file(hostname))
      assert_match(/server_name #{Regexp.escape(hostname)};/, body,
                   "#{hostname} has no product shell")
      assert_match(/server_name core\.#{Regexp.escape(hostname)};/, body,
                   "#{hostname} has no Backoffice")
    end
  end

  test "a domain's blocks name that domain and no other" do
    @router.write_domains(%w[first.test second.test])

    assert_no_match(/second\.test/, File.read(domain_file("first.test")),
                    "one domain's file naming another is how a request reaches the wrong shell")
  end

  test "the rendered domain config carries no unsubstituted placeholders" do
    @router.write_domains(["first.test"])

    body = File.read(domain_file("first.test"))
    assert_no_match(/\$\{[A-Z_]+\}/, body,
                    "an unsubstituted placeholder is a config nginx refuses, which takes every domain down")
  end

  # Rewritten whole rather than added to. A server block for a domain nobody
  # serves keeps answering, and the answer looks correct.
  test "a domain that is no longer served loses its file" do
    @router.write_domains(%w[first.test second.test])
    assert File.exist?(domain_file("second.test"))

    @router.write_domains(["first.test"])

    assert File.exist?(domain_file("first.test"))
    refute File.exist?(domain_file("second.test")), "a withdrawn domain must stop being served"
  end

  test "writing the same domains twice changes nothing" do
    @router.write_domains(["first.test"])
    before = File.read(domain_file("first.test"))

    @router.write_domains(["first.test"])

    assert_equal before, File.read(domain_file("first.test"))
  end

  test "the template's own explanation does not travel into the domain config" do
    @router.write_domains(["first.test"])

    refute File.read(domain_file("first.test")).start_with?("#"),
           "the header explains placeholders that no longer exist once rendered"
  end
end

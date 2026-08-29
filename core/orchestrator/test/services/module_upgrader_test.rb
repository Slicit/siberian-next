# frozen_string_literal: true

require "test_helper"
require "support/fake_engine"

# Upgrading is not uninstalling and installing again, and these are the
# differences that matter: what survives, and what happens when the new version
# does not come up.
class ModuleUpgraderTest < ActiveSupport::TestCase
  setup do
    @engine = FakeEngine.new
    @router = FakeRouter.new
    @domain = Domain.create!(hostname: "example.test", primary: true)
    install
  end

  def body(version: "1.0.0", image: "nginx:1.27-alpine", health: "/up")
    <<~YAML
      schema_version: 1
      name: demo-tasks
      version: #{version}
      title: Demo Tasks
      containers:
        - service: web
          image: #{image}
          role: http
          internal_port: 80
          health:
            path: #{health}
      routes:
        base: /demo-tasks
        entry: web
    YAML
  end

  def manifest(**options) = Siberian::Contracts::Manifest.parse(body(**options))

  def install
    ModuleInstaller.new(manifest, driver: @engine, router: @router,
                        domains: [@domain], probe: FakeProbe).call
    @installed = InstalledModule.find_by!(name: "demo-tasks")
  end

  def upgrade(probe: FakeProbe, **options)
    ModuleUpgrader.new(@installed, manifest(**options), driver: @engine, router: @router,
                       domains: [@domain], probe: probe).call
  end

  test "a new version replaces the containers" do
    result = upgrade(version: "2.0.0", image: "nginx:1.28-alpine")

    assert result.success?
    assert result.changed?
    assert_equal "2.0.0", @installed.reload.version
    assert_equal ["nginx:1.28-alpine"], @installed.module_containers.pluck(:image)
  end

  # The whole reason this is not a remove and an install. The uuid is what names
  # the network, the containers, and every provisioned database and bucket.
  test "the module keeps its identity, so it keeps its data" do
    uuid = @installed.uuid
    network = @installed.network_name

    upgrade(version: "2.0.0", image: "nginx:1.28-alpine")

    assert_equal uuid, @installed.reload.uuid
    assert_equal network, @installed.network_name
  end

  test "the same version with the same images is a no-op that says so" do
    result = upgrade

    assert result.success?
    refute result.changed?
    assert_match(/already at 1\.0\.0/, result.error,
                 "an operator who rebuilt an image under the same tag must be told nothing changed")
  end

  # A tag that moved without the version. Rebuilding under a new tag is a real
  # change even when the version did not move.
  test "the same version with a different image is not a no-op" do
    result = upgrade(image: "nginx:1.28-alpine")

    assert result.success?
    assert result.changed?
  end

  test "a manifest for another module is refused" do
    other = Siberian::Contracts::Manifest.parse(body.sub("name: demo-tasks", "name: something-else"))

    assert_raises(ModuleUpgrader::WrongModule) do
      ModuleUpgrader.new(@installed, other, driver: @engine, router: @router,
                         domains: [@domain], probe: FakeProbe).call
    end
  end

  # The thing uninstall-and-install could never do.
  test "a version that does not serve what it declares is rolled back" do
    result = upgrade(version: "2.0.0", image: "nginx:1.28-alpine", probe: FakeProbe.answering(false))

    refute result.success?
    assert_match(/put back/, result.error)
  end

  test "and the working version is what is left running" do
    upgrade(version: "2.0.0", image: "nginx:1.28-alpine", probe: FakeProbe.answering(false))
    @installed.reload

    assert_equal "1.0.0", @installed.version,
                 "a failed upgrade must leave the version that worked, not the one that did not"
    assert_equal ["nginx:1.27-alpine"], @installed.module_containers.pluck(:image)
    assert_equal 1, @installed.module_containers.count,
                 "the failed containers must not be left beside the restored ones"
  end

  test "the routes are republished, because a port can change between versions" do
    @router.written.clear
    upgrade(version: "2.0.0", image: "nginx:1.28-alpine")

    assert_includes @router.written.map(&:first), "demo-tasks"
  end

  test "every step is recorded" do
    upgrade(version: "2.0.0", image: "nginx:1.28-alpine")

    actions = Activity.order(:id).pluck(:action)
    assert_includes actions, "upgrade.started"
    assert_includes actions, "upgrade.finished"
  end

  test "a rollback is recorded as one" do
    upgrade(version: "2.0.0", image: "nginx:1.28-alpine", probe: FakeProbe.answering(false))

    assert_includes Activity.order(:id).pluck(:action), "upgrade.rolled_back"
  end
end

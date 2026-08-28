# frozen_string_literal: true

require "test_helper"
require "support/fake_engine"

# The reconciler's job is to tell three states apart: what it put right, what is
# wrong and it deliberately will not touch, and what it could not find out.
# Most of these tests are about the middle one, because that is the distinction
# a reconciler usually gets wrong by being helpful.
class ReconcilerTest < ActiveSupport::TestCase
  # Records what it was asked, and answers with whatever the test set up.
  class FakeRegistrar
    attr_reader :reregistered, :asked

    def initialize(known: {}, failing: [])
      @known = known
      @failing = failing
      @reregistered = []
      @asked = []
    end

    def known_modules(service)
      @asked << service
      raise ServiceRegistrar::Error, "#{service} unreachable" if @failing.include?(service)

      Array(@known[service]).to_set
    end

    def reregister_mobile(installed, _manifest)
      raise ServiceRegistrar::Error, "mobile refused" if @failing.include?(:mobile_write)

      @reregistered << installed.name
      "token"
    end
  end

  class FakeRoutes
    def initialize(errors: []) = @errors = errors

    def call
      RouteReconciler::Result.new(joined: ["net"], written: ["demo-tasks"], reloaded: true, errors: @errors)
    end
  end

  class FakeRoles
    def initialize(added: {}, failing: false)
      @added = added
      @failing = failing
    end

    def reconcile!
      raise RoleCatalogue::Error, "auth unreachable" if @failing

      @added
    end
  end

  setup do
    @engine = FakeEngine.new
    @router = FakeRouter.new
    @domain = Domain.create!(hostname: "example.test", primary: true)
  end

  def install(name, extra = "")
    ModuleInstaller.new(manifest(name, extra), driver: @engine, router: @router, domains: [@domain])
                   .call.installed_module
  end

  def manifest(name, extra)
    Siberian::Contracts::Manifest.parse(<<~YAML)
      schema_version: 1
      name: #{name}
      version: 1.0.0
      title: #{name}
      containers:
        - service: web
          image: nginx:1.27-alpine
          role: http
          internal_port: 80
      routes:
        base: /#{name}
        entry: web
      #{extra}
    YAML
  end

  def reconcile(registrar:, routes: FakeRoutes.new, roles: FakeRoles.new)
    Reconciler.new(registrar: registrar, routes: routes, roles: roles).call
  end

  test "a module the Mobile service never heard of is re-registered" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(known: { mobile: [] })

    result = reconcile(registrar: registrar)

    assert_equal ["demo-tasks"], registrar.reregistered
    assert_includes result.step(:mobile).changed, "mobile: demo-tasks"
  end

  test "a module the Mobile service already knows is still re-sent, but not reported as a change" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(known: { mobile: ["demo-tasks"] })

    result = reconcile(registrar: registrar)

    assert_equal ["demo-tasks"], registrar.reregistered,
                 "the native block can change on update, so re-sending is the point"
    assert_empty result.step(:mobile).changed
    assert result.clean?
  end

  test "a missing storage registration is reported and not repaired" do
    install("demo-tasks", "storage:\n  spaces: [files]\n  quota_mb: 10")
    registrar = FakeRegistrar.new(known: { mobile: ["demo-tasks"], storage: [] })

    result = reconcile(registrar: registrar)

    assert result.ok?, "reporting drift is not an error"
    refute result.clean?
    assert_match(/storage: demo-tasks is not registered/, result.drifted.join)
    assert_empty result.step(:registrations).changed,
                 "repairing this would rotate a token the running container holds"
  end

  test "a module that never asked for storage is not reported as missing from it" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(known: { mobile: ["demo-tasks"], storage: [], database: [], mailer: [] })

    result = reconcile(registrar: registrar)

    assert result.clean?, "reported: #{result.drifted.join('; ')}"
  end

  test "a service that cannot be reached is an error, not silence" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(known: { mobile: ["demo-tasks"] }, failing: [:storage])

    result = reconcile(registrar: registrar)

    refute result.ok?
    assert_match(/storage: could not list/, result.errors.join)
  end

  test "the modules are still re-sent when Mobile cannot be listed" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(failing: [:mobile])

    result = reconcile(registrar: registrar)

    assert_equal ["demo-tasks"], registrar.reregistered,
                 "not knowing what is registered is a reason to send, not to skip"
    refute result.ok?
  end

  test "one module failing does not stop the next" do
    install("alpha")
    install("beta")
    registrar = FakeRegistrar.new(known: { mobile: [] }, failing: [:mobile_write])

    result = reconcile(registrar: registrar)

    assert_equal 2, result.step(:mobile).errors.length
  end

  test "routing errors surface through the routes step" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(known: { mobile: ["demo-tasks"] })

    result = reconcile(registrar: registrar, routes: FakeRoutes.new(errors: ["reload: nope"]))

    refute result.ok?
    assert_includes result.step(:routes).errors, "reload: nope"
  end

  test "permissions delivered to a role are reported as changes" do
    registrar = FakeRegistrar.new(known: { mobile: [] })

    result = reconcile(registrar: registrar, roles: FakeRoles.new(added: { "operator" => ["core.storage.manage"] }))

    assert_includes result.step(:roles).changed, "role operator: core.storage.manage"
  end

  test "Auth being unreachable fails its step without stopping the others" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(known: { mobile: [] })

    result = reconcile(registrar: registrar, roles: FakeRoles.new(failing: true))

    refute result.ok?
    assert_match(/roles: /, result.step(:roles).errors.join)
    assert_equal ["demo-tasks"], registrar.reregistered,
                 "a later step failing must not undo an earlier one"
  end

  test "reconciling a system with nothing wrong reports nothing" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(known: { mobile: ["demo-tasks"] })

    result = reconcile(registrar: registrar)

    assert result.clean?
    assert_empty result.drifted
  end

  test "it records one activity entry saying what it did" do
    install("demo-tasks")
    registrar = FakeRegistrar.new(known: { mobile: [] })

    assert_difference -> { Activity.where(action: "state.reconciled").count }, 1 do
      reconcile(registrar: registrar)
    end
  end
end

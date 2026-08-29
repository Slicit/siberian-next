# frozen_string_literal: true

# An in-memory stand-in for a container engine.
#
# The engine driver has its own suite, against both a mocked client and a real
# daemon. These tests are about what the Orchestrator does with a driver, so the
# driver here is a record of calls rather than a container runtime.
class FakeEngine
  attr_reader :networks, :containers, :calls, :execs

  def initialize(fail_on: nil)
    @networks = []
    @containers = {}
    @attachments = {}
    @calls = []
    @execs = []
    @fail_on = fail_on
    @next_id = 0
  end

  def create_network(name)
    fail_if!(:create_network)
    raise Siberian::Engine::Driver::AlreadyExists, name if @networks.include?(name)

    @networks << name
    @calls << [:create_network, name]
    name
  end

  def remove_network(name)
    # The real engine refuses while anything is still attached, and that refusal
    # is the reason uninstall used to leave a network behind every time. A
    # double that removes it regardless cannot fail the way the real one did.
    attached = @attachments.fetch(name, [])
    raise Siberian::Engine::Driver::Error, "#{name} still has #{attached.join(', ')} attached" if attached.any?

    @networks.delete(name)
    @calls << [:remove_network, name]
    true
  end

  # Attaching and detaching an existing container to a module network. The
  # Router and the module data cluster both join every module network, and both
  # have to come off again before the network can go.
  def attach(id, network:, aliases: [])
    @attachments[network] ||= []
    @attachments[network] << id unless @attachments[network].include?(id)
    @calls << [:attach, id, network, aliases]
    true
  end

  def detach(id, network:)
    @attachments.fetch(network, []).delete(id)
    @calls << [:detach, id, network]
    true
  end

  # Who is currently on a network, for a test that wants to assert about it.
  def attached_to(network) = @attachments.fetch(network, [])

  def create(spec, network:)
    fail_if!(:create)
    @next_id += 1
    id = "engine-#{@next_id}"
    @containers[id] = { spec: spec, network: network, state: :stopped }
    @calls << [:create, spec.name]
    id
  end

  def start(id)
    fail_if!(:start)
    raise Siberian::Engine::Driver::NotFound, id unless @containers.key?(id)

    @containers[id][:state] = :running
    @calls << [:start, id]
    true
  end

  def stop(id, timeout_seconds: 10)
    @containers[id][:state] = :stopped if @containers.key?(id)
    @calls << [:stop, id]
    true
  end

  def remove(id, force: false)
    @containers.delete(id)
    @calls << [:remove, id]
    true
  end

  def status(id)
    @containers.dig(id, :state) || :absent
  end

  def healthy?(id) = status(id) == :running

  def exec_in(id, command, detach: false)
    fail_if!(:exec_in)
    @execs << [id, command]
    ""
  end

  def list(labels: {}) = []
  def pull(image) = true
  def image_present?(image) = true
  def version = "fake"

  # Names the containers that exist, for readable assertions.
  def container_names = @containers.values.map { |c| c[:spec].name }

  private

  def fail_if!(operation)
    raise Siberian::Engine::Driver::Error, "engine refused #{operation}" if @fail_on == operation
  end
end

# Captures router writes instead of touching a shared volume, and records
# whether a reload followed a write. A write with no reload is invisible to
# nginx, so the tests need to see both.
class FakeRouter
  attr_reader :written, :removed, :reloads, :joined_networks, :left_networks

  def initialize(fail_reload: false)
    @written = {}
    @removed = []
    @reloads = 0
    @joined_networks = []
    @left_networks = []
    @fail_reload = fail_reload
  end

  def join_network(name)
    @joined_networks << name
    true
  end

  def leave_network(name)
    @left_networks << name
    @joined_networks.delete(name)
    true
  end

  def write(installed_module, domains)
    @written[installed_module.name] = Array(domains).map(&:to_s)
  end

  def remove(installed_module)
    @removed << installed_module.name
    @written.delete(installed_module.name)
  end

  def reload
    raise RouterConfig::ReloadFailed, "nginx said no" if @fail_reload

    @reloads += 1
    true
  end

  def write_and_reload(installed_module, domains)
    write(installed_module, domains)
    reload
  end

  # The map from module name to upstream, rewritten whole on every install,
  # uninstall, and reconcile.
  #
  # Recorded as names rather than ignored, because "which modules are
  # addressable as /m/<name>/" is a thing tests need to assert about and the
  # real RouterConfig rewrites this list rather than appending to it.
  def refresh_upstreams!(installed_modules)
    @upstreams = Array(installed_modules).map(&:name)
  end

  def upstreams = @upstreams ||= []
end

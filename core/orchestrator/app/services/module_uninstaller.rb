# frozen_string_literal: true

# Removes a module: routes first, then containers, then the network.
#
# The order is the reverse of installation and it matters. Pulling the
# containers out from under a live route serves errors to whoever is using the
# module; removing the route first serves a clean 502 for a moment instead.
class ModuleUninstaller
  Result = Struct.new(:success, :error, :warnings, keyword_init: true) do
    def success? = success == true
  end

  def initialize(installed_module,
                 driver: Siberian::Engine.driver,
                 router: RouterConfig.new,
                 registrar: nil,
                 keep_data: true)
    @installed = installed_module
    @driver = driver
    @router = router
    @registrar = registrar
    @keep_data = keep_data
    @warnings = []
  end

  def call
    @installed.update!(status: "removing")
    Activity.record("uninstall.started", installed_module: @installed, outcome: "started")

    withdraw_routes
    remove_containers
    remove_network
    release_provisions

    Activity.record("uninstall.finished", installed_module: @installed, kept_data: @keep_data)
    @installed.destroy!

    Result.new(success: true, warnings: @warnings)
  rescue StandardError => e
    @installed.update(status: "failed", last_error: e.message)
    Activity.record("uninstall.failed", installed_module: @installed, outcome: "failed", detail: e.message)
    Result.new(success: false, error: e.message, warnings: @warnings)
  end

  private

  # Best effort, and deliberately so: a container the engine has already lost
  # should not block an operator from finishing a removal.
  def attempt(description)
    yield
  rescue StandardError => e
    @warnings << "#{description}: #{e.message}"
  end

  def withdraw_routes
    attempt("remove router config") { @router.remove(@installed) }
    attempt("reload router") { @router.reload }
    attempt("detach router from module network") { @router.leave_network(@installed.network_name) }
  end

  def remove_containers
    @installed.module_containers.each do |container|
      id = container.engine_id.presence || container.name
      attempt("stop #{container.name}") { @driver.stop(id) }
      attempt("remove #{container.name}") { @driver.remove(id, force: true) }
    end
  end

  def remove_network
    return if @installed.network_name.blank?

    attempt("remove network #{@installed.network_name}") { @driver.remove_network(@installed.network_name) }
  end

  # Revoking a module's identity is not the same as destroying what it wrote.
  # The services lock the credentials out and keep the data: reinstalling a
  # module to find its files and tables gone is a far worse surprise than a
  # bucket left behind.
  def release_provisions
    return if @registrar.nil?

    attempt("revoke service credentials") { @registrar.revoke(@installed) }
  end
end

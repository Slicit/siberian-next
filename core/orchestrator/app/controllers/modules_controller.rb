# frozen_string_literal: true

class ModulesController < ApplicationController
  requires "core.modules.read"
  requires "core.modules.remove", only: :destroy
  # Replacing what is running is installing, not reading.
  requires "core.modules.install", only: :upgrade
  before_action :set_module, only: %i[show refresh destroy]

  def index
    @modules = InstalledModule.ordered.includes(:module_containers, :capabilities)
  end

  def show
    # What the catalogue holds now, so the page can offer an upgrade only when
    # there is one to offer.
    @available_version = catalog.find(@module.name)&.manifest&.version
    @breadcrumb_leaf = @module.title.presence || @module.name
    @activities = @module.activities.recent.limit(25)
    @registry = InterfaceRegistry.new
    # How this module appears in each domain's phone app, which is a question
    # about this module and belongs on its page rather than only on the app's.
    @mobile = Siberian::MobileClient.new(logger: Rails.logger).apps
  end

  # Asks the engine what is actually running, rather than trusting what we
  # recorded at install time. The two drift: containers crash, operators
  # intervene, hosts reboot.
  def refresh
    @module.module_containers.find_each do |container|
      id = container.engine_id.presence || container.name
      begin
        container.update(state: driver.status(id).to_s, state_checked_at: Time.current)
      rescue StandardError => e
        container.update(state: "absent", state_checked_at: Time.current)
        Rails.logger.warn("could not read #{container.name}: #{e.message}")
      end
    end

    @module.update(status: @module.derived_status)
    redirect_to module_path(@module.name), notice: "Container states refreshed from the engine."
  end

  # Moving to whatever the catalogue now holds for this module.
  #
  # An upgrade rather than a remove and install: the module keeps its uuid, its
  # network, its databases and its buckets, and only the containers are
  # replaced. If the new version does not come up, the old one is put back,
  # which is the thing uninstall-and-install could never do.
  def upgrade
    entry = catalog.find(@module.name)
    return redirect_to module_path(@module.name), alert: "#{@module.name} is not in the catalogue." if entry.nil?

    result = ModuleUpgrader.new(@module, entry.manifest, registrar: ServiceRegistrar.new).call

    if result.success? && result.changed?
      notice = "#{@module.name} is now at #{result.installed_module.version}."
      notice += " Warnings: #{result.warnings.join('; ')}" if result.warnings.any?
      redirect_to module_path(@module.name), notice: notice
    elsif result.success?
      # Nothing changed, and said so. An operator who rebuilt an image under the
      # same tag would otherwise be told it worked and find nothing different.
      redirect_to module_path(@module.name), alert: result.error
    else
      redirect_to module_path(@module.name), alert: "Upgrade failed: #{result.error}"
    end
  end

  def destroy
    # Fresh rather than cached: an operator who has just had this taken away
    # should not get one more removal out of a thirty second window.
    require_fresh_permission!("core.modules.remove")
    return if performed?

    result = ModuleUninstaller.new(@module, registrar: ServiceRegistrar.new,
                                   keep_data: params[:keep_data] != "false").call

    if result.success?
      message = "#{@module.name} removed."
      message += " Warnings: #{result.warnings.join('; ')}" if result.warnings.any?
      redirect_to modules_path, notice: message
    else
      redirect_to module_path(@module.name), alert: "Could not remove: #{result.error}"
    end
  end

  private

  def set_module
    @module = InstalledModule.find_by(name: params[:name])
    return if @module

    redirect_to modules_path, alert: "No module named #{params[:name]}."
  end
end

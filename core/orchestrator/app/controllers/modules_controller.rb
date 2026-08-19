# frozen_string_literal: true

class ModulesController < ApplicationController
  before_action :set_module, only: %i[show refresh destroy]

  def index
    @modules = InstalledModule.ordered.includes(:module_containers, :capabilities)
  end

  def show
    @activities = @module.activities.recent.limit(25)
    @registry = InterfaceRegistry.new
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

  def destroy
    result = ModuleUninstaller.new(@module, keep_data: params[:keep_data] != "false").call

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

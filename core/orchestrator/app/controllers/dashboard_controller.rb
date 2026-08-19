# frozen_string_literal: true

class DashboardController < ApplicationController
  def show
    @modules = InstalledModule.ordered.includes(:module_containers)
    @domains = Domain.ordered
    @activities = Activity.recent.includes(:installed_module).limit(8)
    @health = CoreHealth.new
    @catalog_entries = catalog.entries
    @registry = InterfaceRegistry.new
  end
end

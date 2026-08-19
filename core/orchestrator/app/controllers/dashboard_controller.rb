# frozen_string_literal: true

class DashboardController < ApplicationController
  before_action :require_any_backoffice_permission!

  def show
    @modules = allow?("core.modules.read") ? InstalledModule.ordered.includes(:module_containers) : []
    @domains = allow?("core.domains.manage") ? Domain.ordered : []
    @activities = allow?("core.audit.read") ? Activity.recent.includes(:installed_module).limit(8) : []
    @health = CoreHealth.new
    @catalog_entries = allow?("core.modules.install") ? catalog.entries : []
    @registry = InterfaceRegistry.new
  end

  private

  # The overview shows core health, installed modules, and domains, which is
  # plenty to be worth withholding. Signing in is not a reason to see it, so
  # somebody with no Backoffice permission at all is turned away here rather
  # than shown a page assembled from things they cannot open.
  BACKOFFICE = %w[core.modules.read core.users.read core.roles.manage
                  core.domains.manage core.audit.read].freeze

  def require_any_backoffice_permission!
    return if current_user && BACKOFFICE.any? { |permission| allow?(permission) }

    @missing_permission = BACKOFFICE.first
    render "shared/not_permitted", status: :forbidden
  end
end

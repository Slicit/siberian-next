# frozen_string_literal: true

# What the Base App renders, and where.
#
# The shell asks for capabilities by area and gets back somewhere to point an
# iframe. It never learns a container name, a uuid, or a network: a module is a
# title, an area, and a URL.
module Internal
  class CapabilitiesController < ActionController::API
    include Siberian::ServiceAuthentication
    permit_services :base

    # GET /internal/capabilities
    def index
      domain = params[:domain].presence || request.headers["X-Siberian-Domain"].presence
      scope = Capability.features.includes(:installed_module)
      scope = scope.where(area: params[:area]) if params[:area].present?

      capabilities = scope.ordered.filter_map do |capability|
        next unless capability.installed_module.live?

        {
          id: capability.capability_id,
          title: capability.title,
          area: capability.area,
          icon: capability.icon,
          module: capability.installed_module.name,
          module_title: capability.installed_module.title,
          status: capability.installed_module.status,
          url: domain ? capability.url_for(domain) : nil,
          path: capability.path
        }
      end

      render json: { capabilities: capabilities, areas: capabilities.map { |c| c[:area] }.uniq }
    end

    private

  end
end

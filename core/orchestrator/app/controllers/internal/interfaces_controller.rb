# frozen_string_literal: true

# Which implementation currently answers a core interface.
#
# The Mailer asks this before every delivery attempt rather than once per
# message, so installing a transport module drains a queue that is already
# backed up without anybody re-queuing anything.
module Internal
  class InterfacesController < ActionController::API
    include Siberian::ServiceAuthentication
    permit_services :mailer

    # GET /internal/interfaces/:name
    def show
      registry = InterfaceRegistry.new
      implementation = registry.resolve(params[:name])

      render json: {
        interface: params[:name],
        implementation: implementation && {
          provider: implementation.provider,
          url: implementation.url,
          priority: implementation.priority,
          built_in: implementation.built_in?
        },
        alternatives: registry.implementations(params[:name]).drop(1).map do |other|
          { provider: other.provider, priority: other.priority, built_in: other.built_in? }
        end
      }
    end

    private

  end
end

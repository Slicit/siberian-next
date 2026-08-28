# frozen_string_literal: true

# The whole audit trail, for the Backoffice.
module Admin
  class AuditController < ApplicationController
    include Siberian::ServiceAuthentication
    permit_services :orchestrator

    # GET /admin/audit
    def index
      events = AuditEvent.recent
      events = events.for_module(params[:module_name]) if params[:module_name].present?
      # Refusals are usually the interesting ones, so they get their own filter.
      events = events.refusals if params[:refusals] == "true"

      render json: {
        events: events.limit([params.fetch(:limit, 200).to_i, 1000].min).map { |event| serialize(event) }
      }
    end

    private

    def serialize(event)
      {
        module_name: event.module_name,
        domain: event.domain,
        action: event.action,
        subject: event.subject,
        outcome: event.outcome,
        row_count: event.row_count,
        detail: event.detail,
        occurred_at: event.occurred_at
      }
    end

  end
end

# frozen_string_literal: true

# A module can read its own audit trail.
#
# Transparency is cheap here and the alternative is worse: a module author who
# cannot see what was recorded about their module has to guess.
class AuditController < ApplicationController
  include ModuleAuthentication

  # GET /v1/audit
  def index
    events = AuditEvent.for_module(current_module.module_name).recent.limit(200)
    render json: { events: events.map { |event| serialize(event) } }
  end

  private

  def serialize(event)
    {
      action: event.action,
      subject: event.subject,
      outcome: event.outcome,
      domain: event.domain,
      row_count: event.row_count,
      detail: event.detail,
      occurred_at: event.occurred_at
    }
  end
end

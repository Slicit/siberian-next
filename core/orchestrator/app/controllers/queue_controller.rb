# frozen_string_literal: true

# The mail queue, and the database audit trail: the two things the system was
# doing that an operator could not see.
#
# Both existed behind admin endpoints and needed curl and a token to reach,
# which is the moment somebody would least want to be reaching for either. Mail
# now carries password resets, so "why is mail not arriving" stopped being a
# question anybody can leave for later.
class QueueController < ApplicationController
  requires "core.modules.read"
  requires "core.audit.read", only: %i[audit]
  # Putting a dead message back is the one action here that changes anything.
  requires "core.modules.install", only: %i[retry_message]

  def index
    @report = mailer.queue(state: params[:state].presence,
                           unacknowledged: params[:unacknowledged].presence)
    @messages = Array(@report && @report["messages"])
    @counts = (@report && @report["counts"]) || {}
    @state = params[:state].presence
  end

  def retry_message
    result = mailer.retry_message(params[:id])

    redirect_to queue_path,
                **(result ? { notice: "Message #{params[:id]} is queued again." }
                          : { alert: "That message could not be retried. Only a dead or cancelled one can be." })
  end

  def audit
    @report = database.audit(module_name: params[:module_name].presence,
                             refusals: params[:refusals].presence)
    @events = Array(@report && @report["events"])
    @module_name = params[:module_name].presence
    @refusals = params[:refusals] == "true"
  end

  private

  def mailer
    @mailer ||= Siberian::MailerClient.new(logger: Rails.logger)
  end

  def database
    @database ||= Siberian::DatabaseClient.new(logger: Rails.logger)
  end
end

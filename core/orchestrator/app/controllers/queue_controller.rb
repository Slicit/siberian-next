# frozen_string_literal: true

# The mail queue: every message the system has been handed, and what happened.
#
# It existed behind an admin endpoint and needed curl and a token to reach,
# which is the moment somebody would least want to be reaching for one. Mail now
# carries password resets, so "why is mail not arriving" stopped being a
# question anybody can leave for later.
class QueueController < ApplicationController
  requires "core.modules.read"
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

  private

  def mailer
    @mailer ||= Siberian::MailerClient.new(logger: Rails.logger)
  end
end

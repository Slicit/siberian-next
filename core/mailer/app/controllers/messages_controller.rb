# frozen_string_literal: true

# The whole module-facing surface of the Mailer.
#
# A module hands over a message and stops thinking about it, which is only
# honest because something else keeps thinking about it. What it gets back is a
# queue it can inspect, outcomes it has to acknowledge, and a retry it can ask
# for by hand.
class MessagesController < ApplicationController
  include ModuleAuthentication

  # POST /v1/messages
  def create
    if current_module.over_daily_limit?
      return render json: {
        error: "daily limit reached", daily_limit: current_module.daily_limit,
        sent_today: current_module.sent_today
      }, status: :too_many_requests
    end

    key = params[:idempotency_key].presence

    # Enqueuing the same key twice is one message. A module retrying its own
    # request after a timeout should not send twice, and it cannot tell from
    # its side whether the first one landed.
    if key && (existing = scope.find_by(idempotency_key: key))
      return render json: existing.summary.merge(deduplicated: true), status: :ok
    end

    message = scope.build(message_params.merge(
      module_registration: current_module,
      domain: current_domain,
      idempotency_key: key,
      state: Message::QUEUED,
      next_attempt_at: Time.current
    ))

    if message.save
      render json: message.summary, status: :created
    else
      render json: { errors: message.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # GET /v1/messages
  #
  # The queue, filtered. `unacknowledged=true` is the one a module polls: it
  # returns terminal outcomes nobody has said they have seen.
  def index
    messages = scope.recent

    messages = messages.where(state: params[:state]) if params[:state].present?
    messages = messages.unacknowledged if params[:unacknowledged] == "true"
    messages = messages.pending if params[:pending] == "true"

    limit = [params.fetch(:limit, 100).to_i, 500].min
    messages = messages.limit(limit)

    render json: {
      messages: messages.map(&:summary),
      counts: counts,
      domain: current_domain
    }
  end

  # GET /v1/messages/:id
  def show
    message = scope.find_by(id: params[:id])
    return render json: { error: "no such message" }, status: :not_found if message.nil?

    render json: message.detail
  end

  # POST /v1/messages/:id/ack
  #
  # Until this is called, a terminal outcome keeps being reported. A growing
  # pile of unacknowledged messages is a module that is not looking, which
  # should be visible rather than quiet.
  def acknowledge
    message = scope.find_by(id: params[:id])
    return render json: { error: "no such message" }, status: :not_found if message.nil?

    unless message.terminal?
      return render json: {
        error: "nothing to acknowledge yet", state: message.state
      }, status: :conflict
    end

    message.acknowledge!
    render json: message.summary
  end

  # POST /v1/messages/ack
  #
  # Acknowledging one at a time turns a poll of fifty outcomes into fifty
  # round trips, so the batch exists.
  def acknowledge_many
    ids = Array(params[:ids]).map(&:to_i)
    return render json: { error: "ids is required" }, status: :bad_request if ids.empty?

    acknowledged = scope.terminal.where(id: ids).where(acknowledged_at: nil)
    count = acknowledged.update_all(acknowledged_at: Time.current)

    render json: { acknowledged: count, requested: ids.length, counts: counts }
  end

  # POST /v1/messages/:id/retry
  def retry_message
    message = scope.find_by(id: params[:id])
    return render json: { error: "no such message" }, status: :not_found if message.nil?

    unless message.dead? || message.cancelled?
      return render json: {
        error: "only a dead or cancelled message can be retried", state: message.state
      }, status: :conflict
    end

    message.revive!(max_attempts: params[:max_attempts]&.to_i)
    render json: message.summary
  end

  # DELETE /v1/messages/:id
  def destroy
    message = scope.find_by(id: params[:id])
    return render json: { error: "no such message" }, status: :not_found if message.nil?

    unless message.cancel!
      return render json: { error: "already #{message.state}" }, status: :conflict
    end

    render json: message.summary
  end

  # GET /v1/stats
  def stats
    render json: {
      counts: counts,
      unacknowledged: scope.unacknowledged.count,
      oldest_pending: scope.pending.minimum(:created_at),
      next_attempt_at: scope.pending.minimum(:next_attempt_at),
      sent_today: current_module.sent_today,
      daily_limit: current_module.daily_limit,
      domain: current_domain
    }
  end

  private

  def counts
    Message::STATES.index_with { |state| scope.where(state: state).count }
  end

  def message_params
    params.permit(:to, :cc, :bcc, :from, :reply_to, :subject, :text_body, :html_body,
                  :max_attempts, headers: {})
  end
end

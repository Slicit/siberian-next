# frozen_string_literal: true

# The Orchestrator's way in: register a module so it can queue mail.
module Admin
  class ModulesController < ApplicationController
    include Siberian::ServiceAuthentication
    permit_services :orchestrator

    # GET /admin/modules
    #
    # What this service knows, so the Orchestrator can compare it against what
    # it installed. Names and shape only: a reconciler needs to know whether a
    # registration exists, never what its token is.
    def index
      render json: {
        modules: ModuleRegistration.active.order(:module_name).map do |registration|
          {
            module_name: registration.module_name,
            module_uuid: registration.module_uuid,
            daily_limit: registration.daily_limit
          }
        end
      }
    end

    # POST /admin/modules
    def create
      registration, token = ModuleRegistration.register!(
        module_name: params.require(:module_name),
        module_uuid: params.require(:module_uuid),
        daily_limit: params[:daily_limit]
      )

      render json: {
        module_name: registration.module_name,
        daily_limit: registration.daily_limit,
        token: token
      }, status: :created
    end

    # GET /admin/queue
    #
    # The whole queue, across modules, for the Backoffice. A module sees only
    # its own; an operator has to be able to see why nothing is arriving.
    def queue
      messages = Message.recent.includes(:module_registration)
      messages = messages.where(state: params[:state]) if params[:state].present?
      messages = messages.unacknowledged if params[:unacknowledged] == "true"

      render json: {
        messages: messages.limit([params.fetch(:limit, 100).to_i, 500].min).map do |message|
          message.summary.merge(module_name: message.sender_name)
        end,
        counts: Message::STATES.index_with { |state| Message.where(state: state).count },
        unacknowledged: Message.unacknowledged.count,
        modules: ModuleRegistration.active.pluck(:module_name)
      }
    end


    # POST /admin/queue/:id/retry
    def retry_message
      message = Message.find_by(id: params[:id])
      return render json: { error: "no such message" }, status: :not_found if message.nil?

      unless message.dead? || message.cancelled?
        return render json: {
          error: "only a dead or cancelled message can be retried", state: message.state
        }, status: :conflict
      end

      message.revive!
      render json: message.summary.merge(module_name: message.sender_name)
    end
    # DELETE /admin/modules/:module_name
    def destroy
      registration = ModuleRegistration.find_by!(module_name: params[:module_name])
      registration.update!(revoked_at: Time.current)

      # Queued mail is cancelled rather than left to send from a module that no
      # longer exists.
      registration.messages.pending.find_each(&:cancel!)

      head :no_content
    end

    private

  end
end

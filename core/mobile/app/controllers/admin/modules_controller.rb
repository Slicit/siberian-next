# frozen_string_literal: true

# Modules, as the Mobile service knows them. Written by the Orchestrator at
# install and update time, never by the module itself: what a module ships
# natively runs inside somebody's app, so it is approved before it exists here.
module Admin
  class ModulesController < ApplicationController
    before_action :authenticate_admin!

    # POST /admin/modules
    def create
      registration = ModuleRegistration.find_or_initialize_by(module_name: params.require(:module_name))
      token = ModuleRegistration.issue_token

      registration.assign_attributes(
        module_uuid: params.require(:module_uuid),
        token_digest: ModuleRegistration.digest(token),
        native_entry: params[:native_entry],
        fallback: params[:fallback].presence || ModuleRegistration::WEBVIEW,
        base_route: params[:base_route],
        origin: params[:origin],
        revoked_at: nil
      )

      ActiveRecord::Base.transaction do
        registration.save!
        replace_screens(registration, params[:screens])
        replace_requirements(registration, params[:requires])
      end

      render json: serialize(registration).merge(token: token), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    end

    # GET /admin/modules
    def index
      render json: { modules: ModuleRegistration.live.ordered.map { |m| serialize(m) } }
    end

    # DELETE /admin/modules/:module_name
    #
    # Revoked rather than deleted. A build that already went out was built from
    # this, and a row that vanishes takes the explanation with it.
    def destroy
      registration = ModuleRegistration.find_by(module_name: params[:module_name])
      return head :no_content if registration.nil?

      registration.update!(revoked_at: Time.current)
      head :no_content
    end

    private

    def replace_screens(registration, screens)
      registration.module_screens.destroy_all

      Array(screens).each do |screen|
        attributes = screen.respond_to?(:permit) ? screen.permit(:capability, :component, :title, :icon).to_h : screen
        registration.module_screens.create!(attributes)
      end
    end

    # Stored as asked for, never as granted. Whether a capability is on is
    # decided per app, by an operator.
    def replace_requirements(registration, requires)
      registration.module_requirements.destroy_all

      Array(requires).map(&:to_s).uniq.each do |capability|
        registration.module_requirements.create!(capability: capability)
      end
    end

    def serialize(registration)
      {
        module_name: registration.module_name,
        module_uuid: registration.module_uuid,
        fallback: registration.fallback,
        ships_native: registration.ships_native?,
        screens: registration.module_screens.map { |s| { capability: s.capability, component: s.component } },
        requires: registration.required_capabilities
      }
    end
  end
end

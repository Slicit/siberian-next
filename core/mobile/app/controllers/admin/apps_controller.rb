# frozen_string_literal: true

# The app for one domain, and what it is built with. For the Backoffice.
module Admin
  class AppsController < ApplicationController
    before_action :authenticate_admin!

    # GET /admin/apps
    def index
      render json: {
        catalogue: Siberian::MobileCapabilities::CATALOGUE,
        apps: MobileApp.ordered.map { |app| serialize(app) }
      }
    end

    # GET /admin/apps/:domain
    def show
      app = MobileApp.find_by(domain: params[:domain])
      return render json: { error: "no app for that domain" }, status: :not_found if app.nil?

      render json: serialize(app)
    end

    # PUT /admin/apps/:domain
    #
    # One app per domain, so this creates or updates rather than making an
    # operator ask which they are doing.
    def upsert
      app = MobileApp.find_or_initialize_by(domain: params[:domain])
      app.name = params[:name].presence || app.name || params[:domain]
      app.bundle_identifier = params[:bundle_identifier].presence ||
                              app.bundle_identifier ||
                              MobileApp.bundle_identifier_for(params[:domain])
      app.version = params[:version].presence || app.version || "1.0.0"
      app.primary_color = params[:primary_color] if params.key?(:primary_color)
      app.icon_path = params[:icon_path] if params.key?(:icon_path)

      if app.save
        render json: serialize(app)
      else
        render json: { errors: app.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /admin/apps/:domain/capabilities/:capability
    #
    # Switching one capability on or off, and supplying whatever it needs to
    # work. A capability a module requires is still switched on here: the
    # manifest asked, an operator decides.
    def update_capability
      app = MobileApp.find_by(domain: params[:domain])
      return render json: { error: "no app for that domain" }, status: :not_found if app.nil?

      unless Siberian::MobileCapabilities.known?(params[:capability])
        return render json: { error: "no such capability" }, status: :not_found
      end

      row = app.app_capabilities.find_or_initialize_by(capability: params[:capability])
      row.enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled]) != false
      row.source = params[:source].presence || row.source || AppCapability::OPERATOR
      row.settings = row.settings.to_h.merge(params[:settings].to_h) if params[:settings].present?

      if row.save
        render json: serialize(app)
      else
        render json: { errors: row.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /admin/apps/:domain
    def destroy
      app = MobileApp.find_by(domain: params[:domain])
      return render json: { error: "no app for that domain" }, status: :not_found if app.nil?

      app.destroy!
      head :no_content
    end

    private

    def serialize(app)
      enabled = app.enabled_capabilities

      {
        domain: app.domain,
        name: app.name,
        bundle_identifier: app.bundle_identifier,
        version: app.version,
        build_number: app.build_number,
        primary_color: app.primary_color,
        icon_path: app.icon_path,
        capabilities: app.app_capabilities.order(:capability).map do |row|
          {
            capability: row.capability,
            label: row.label,
            enabled: row.enabled,
            source: row.source,
            settings: row.redacted_settings
          }
        end,
        misconfigured: app.misconfigured_capabilities,
        # What each module would contribute if a build ran now, and why. The
        # reason matters more than the answer: "requires location" is something
        # an operator can act on, "not available" is not.
        modules: ModuleRegistration.live.ordered.map do |registration|
          registration.contribution_for(enabled)
                      .merge(name: registration.module_name,
                             requires: registration.required_capabilities)
        end,
        latest_build: app.latest_build && serialize_build(app.latest_build)
      }
    end

    def serialize_build(build)
      {
        id: build.id, platform: build.platform, state: build.state,
        attempts: build.attempts, last_error: build.last_error,
        artifact_path: build.artifact_path, artifact_bytes: build.artifact_bytes,
        created_at: build.created_at, finished_at: build.finished_at
      }
    end
  end
end

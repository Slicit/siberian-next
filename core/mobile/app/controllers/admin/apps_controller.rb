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
      app.theme = params[:theme] if params.key?(:theme)
      if params.key?(:follow_device_scheme)
        app.follow_device_scheme = params[:follow_device_scheme].to_s == "true"
      end
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

      # Only the keys this capability declares. A settings hash is a place
      # somebody could otherwise put anything, and it is handed to a builder
      # that runs third-party code.
      if params[:settings].present?
        allowed = Array(Siberian::MobileCapabilities.find(params[:capability])[:settings]).map { |setting| setting[:key] }
        row.settings = row.settings.to_h.merge(params[:settings].permit(*allowed).to_h)
      end

      if row.save
        render json: serialize(app)
      else
        render json: { errors: row.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # POST /admin/apps/:domain/splash
    #
    # The still image, on every platform. Square, because it is centred on
    # screens of every shape and a rectangle would have to be cropped somewhere.
    def upload_splash
      app = MobileApp.find_by(domain: params[:domain])
      return render json: { error: "no app for that domain" }, status: :not_found if app.nil?

      bytes = request.body.read
      result = SplashAsset.inspect_image(bytes)
      return render json: { errors: result.problems }, status: :unprocessable_entity unless result.ok?

      stored = StorageAccess.new.store(domain: app.domain, path: "splash/#{app.bundle_identifier}.png",
                                       body: bytes, content_type: "image/png")

      app.update!(splash_image_path: stored[:path],
                  splash_background: params[:background].presence || app.splash_background)

      render json: serialize(app).merge(warnings: result.warnings,
                                        image: { width: result.width, height: result.height })
    rescue StorageAccess::Refused => e
      render json: { errors: [e.message] }, status: :insufficient_storage
    end

    # POST /admin/apps/:domain/splash/animation
    #
    # Android only, and only an AnimatedVectorDrawable: that is the one thing
    # the platform splash screen API animates.
    def upload_splash_animation
      app = MobileApp.find_by(domain: params[:domain])
      return render json: { error: "no app for that domain" }, status: :not_found if app.nil?

      bytes = request.body.read
      result = SplashAsset.inspect_animation(bytes)
      return render json: { errors: result.problems }, status: :unprocessable_entity unless result.ok?

      stored = StorageAccess.new.store(domain: app.domain, path: "splash/#{app.bundle_identifier}.xml",
                                       body: bytes, content_type: "application/xml")

      app.update!(splash_animation_path: stored[:path],
                  splash_animation_duration_ms: params[:duration_ms].presence || app.splash_animation_duration_ms)

      render json: serialize(app).merge(warnings: result.warnings)
    rescue StorageAccess::Refused => e
      render json: { errors: [e.message] }, status: :insufficient_storage
    end

    # GET /admin/apps/:domain/preview/*path
    #
    # The exported site, one file at a time. Served from here rather than linked
    # from Storage so the preview has one address, and so the Backoffice can
    # frame it without learning where the object store is.
    def preview
      app = MobileApp.find_by(domain: params[:domain])
      return head :not_found if app.nil?

      relative = params[:path].presence || "index.html"
      return head :bad_request if relative.include?("..")

      body, content_type = StorageAccess.new.fetch(
        domain: app.domain,
        path: "files/previews/#{app.bundle_identifier}/#{relative}"
      )

      return head :not_found if body.nil?

      send_data body, type: content_type.presence || "application/octet-stream", disposition: "inline"
    end

    # DELETE /admin/apps/:domain/splash
    #
    # Forgets the reference. The object stays in Storage, where a build that
    # already used it can still be explained.
    def remove_splash
      app = MobileApp.find_by(domain: params[:domain])
      return render json: { error: "no app for that domain" }, status: :not_found if app.nil?

      if params[:kind] == "animation"
        app.update!(splash_animation_path: nil)
      else
        app.update!(splash_image_path: nil, splash_background: nil)
      end

      render json: serialize(app)
    end

    # POST /admin/apps/:domain/suggest
    #
    # A proposal, never a change. What comes back is shown to a person who
    # accepts it capability by capability, which is the same rule that governs
    # a manifest: something written elsewhere asks, and somebody here decides.
    def suggest
      return render json: { error: "the assistant is not configured" }, status: :service_unavailable unless AppAdvisor.available?

      description = params[:description].to_s.strip
      return render json: { error: "say what the app is for" }, status: :unprocessable_entity if description.empty?

      app = MobileApp.find_by(domain: params[:domain])

      proposal = AppAdvisor.new.call(
        description: description,
        domain: params[:domain],
        app: app && serialize(app).deep_stringify_keys,
        modules: ModuleRegistration.live.ordered.pluck(:module_name)
      )

      render json: { proposal: proposal }
    rescue AppAdvisor::NotConfigured => e
      render json: { error: e.message }, status: :service_unavailable
    rescue AppAdvisor::Refused => e
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.warn("advisor failed: #{e.class}: #{e.message}")
      render json: { error: "the assistant could not be reached" }, status: :bad_gateway
    end

    # DELETE /admin/apps/:domain
    def destroy
      app = MobileApp.find_by(domain: params[:domain])
      return render json: { error: "no app for that domain" }, status: :not_found if app.nil?

      app.destroy!
      head :no_content
    end

    private

    # The Base App reads phone app state to draw the product side menu, so it
    # is admitted here and on no other Mobile endpoint.
    def permitted_callers = %w[orchestrator base]

    def serialize(app)
      enabled = app.enabled_capabilities

      {
        domain: app.domain,
        name: app.name,
        bundle_identifier: app.bundle_identifier,
        version: app.version,
        build_number: app.build_number,
        primary_color: app.primary_color,
        theme: app.theme,
        follow_device_scheme: app.follow_device_scheme,
        icon_path: app.icon_path,
        splash: {
          image: app.splash_image?,
          background: app.splash_background,
          animation: app.splash_animation?,
          animation_duration_ms: app.clamped_animation_duration,
          recommended_px: SplashAsset::RECOMMENDED,
          safe_zone_px: SplashAsset.safe_zone_px
        },
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

# frozen_string_literal: true

# The build queue, for the Backoffice.
module Admin
  class BuildsController < ApplicationController
    before_action :authenticate_admin!

    # GET /admin/builds
    def index
      builds = Build.recent
      builds = builds.where(domain: params[:domain]) if params[:domain].present?

      render json: {
        queued: Build.pending.count,
        building: Build.where(state: Build::BUILDING).count,
        builds: builds.limit(50).map { |build| serialize(build) }
      }
    end

    # POST /admin/builds
    #
    # Queued, not built. The builder is one container shared by every domain, so
    # asking for a build is asking to be next, and saying so is more honest than
    # a request that appears to hang.
    def create
      app = MobileApp.find_by(domain: params.require(:domain))
      return render json: { error: "no app for that domain" }, status: :not_found if app.nil?

      misconfigured = app.misconfigured_capabilities
      if misconfigured.any?
        return render json: {
          error: "some enabled capabilities are missing settings they cannot work without",
          misconfigured: misconfigured
        }, status: :unprocessable_entity
      end

      build = app.builds.create!(
        domain: app.domain,
        platform: params[:platform].presence || Build::ANDROID,
        requested_by: params[:requested_by]
      )

      # Resolved now and kept, so a build can still be explained after the
      # configuration behind it has changed. A build is a thing that happened.
      plan = BuildPlan.new(build).to_h(secrets: false)

      # A static export writes absolute asset paths, so it has to know where it
      # will be served from before it is built. The interface that owns that
      # address is the one that supplies it: this service does not know what
      # route the Backoffice will frame it at.
      plan[:preview] = { base_url: params[:preview_base_url] } if params[:preview_base_url].present?

      build.update!(configuration: plan)

      render json: serialize(build).merge(position: Build.pending.where("id <= ?", build.id).count), status: :accepted
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    end

    # GET /admin/builds/:id
    def show
      build = Build.find_by(id: params[:id])
      return render json: { error: "no such build" }, status: :not_found if build.nil?

      render json: serialize(build).merge(
        log: build.log,
        attempts_detail: build.build_attempts.order(:number).map do |attempt|
          { number: attempt.number, outcome: attempt.outcome, detail: attempt.detail,
            duration_ms: attempt.duration_ms, attempted_at: attempt.attempted_at }
        end
      )
    end

    # POST /admin/builds/:id/cancel
    def cancel
      build = Build.find_by(id: params[:id])
      return render json: { error: "no such build" }, status: :not_found if build.nil?

      return render json: { error: "that build has already finished" }, status: :conflict unless build.cancel!

      render json: serialize(build)
    end

    private

    def serialize(build)
      {
        id: build.id, domain: build.domain, platform: build.platform, state: build.state,
        attempts: build.attempts, last_error: build.last_error,
        artifact_path: build.artifact_path, artifact_bytes: build.artifact_bytes,
        requested_by: build.requested_by, next_attempt_at: build.next_attempt_at,
        created_at: build.created_at, started_at: build.started_at, finished_at: build.finished_at
      }
    end
  end
end

# frozen_string_literal: true

# The build queue.
#
# Read by two callers with different standing. The Backoffice is run by an
# operator and sees every domain; the Base App is inside one and sees that one.
# The difference is enforced here rather than trusted to whoever is asking, so
# adding a caller cannot accidentally hand it the whole system.
module Admin
  class BuildsController < ApplicationController
    before_action :authenticate_admin!
    before_action :require_named_domain!
    before_action :require_own_build!, only: %i[show cancel]

    # GET /admin/builds
    def index
      builds = Build.recent
      builds = builds.where(domain: params[:domain]) if params[:domain].present?

      render json: {
        # The shared queue, across every domain, and deliberately so even for a
        # caller pinned to one: there is a single builder, the page already says
        # so, and "two builds ahead of you" is only useful if it counts the ones
        # that are actually ahead. A count carries no detail about whose they
        # are.
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

    # The Base App reads its own domain's builds. What "its own" means is
    # enforced above rather than taken on trust: see PINNED_CALLERS.
    def permitted_callers = %w[orchestrator base]

    # A pinned caller may only speak about builds on the domain it named. Read
    # from the row rather than from the request, so that knowing an id is not
    # enough to read or cancel somebody else's build.
    def require_own_build!
      return unless pinned_caller?

      build = Build.find_by(id: params[:id])
      return if build.nil? || build.domain == params[:domain]

      # Deliberately the same answer as a build that does not exist. Telling a
      # caller that a build it cannot see exists is itself an answer.
      render json: { error: "no such build" }, status: :not_found
    end

    # Where a waiting build sits in the shared queue. Answered for anybody
    # waiting, because "queued" with no number is the kind of status that makes
    # somebody press the button again.
    def position_of(build) = Build.pending.where("id <= ?", build.id).count

    def serialize(build)
      {
        id: build.id, domain: build.domain, platform: build.platform, state: build.state,
        attempts: build.attempts, last_error: build.last_error,
        artifact_path: build.artifact_path, artifact_bytes: build.artifact_bytes,
        requested_by: build.requested_by, next_attempt_at: build.next_attempt_at,
        created_at: build.created_at, started_at: build.started_at, finished_at: build.finished_at
      }.merge(build.waiting? ? { position: position_of(build) } : {})
    end
  end
end

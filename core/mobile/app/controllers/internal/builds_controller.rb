# frozen_string_literal: true

# The builder's end of the queue.
#
# Deliberately small. The builder runs third-party module code, so it gets one
# claimed build and the plan for it, and cannot ask this service anything else:
# no catalogue, no other domain, no other app's settings.
module Internal
  class BuildsController < ApplicationController
    before_action :authenticate_builder!

    # POST /internal/builds/claim
    #
    # Answers 204 when there is nothing to do, which is most of the time. A
    # worker polling an empty queue should cost a row lock and nothing else.
    def claim
      Build.release_stale!

      # A worker says which lanes it handles. One that says nothing takes
      # anything, so a builder from before lanes existed still works.
      build = Build.claim_next!(lanes: requested_lanes)
      return head :no_content if build.nil?

      # The plan was fixed when the build was queued, so changing a capability
      # does not change a build already in the queue. Credentials are the one
      # exception: they are read now, because a key that was rotated after this
      # was queued is the key that works.
      render json: { build_id: build.id, plan: with_current_secrets(build) }
    end

    # GET /internal/builds/:id/asset/:kind
    #
    # An asset the build needs, streamed out. The builder holds no Storage
    # credential, so it asks for the splash image by kind and gets bytes: it
    # never learns a path, a bucket, or which domain the file sits under.
    def asset
      build = Build.find_by(id: params[:id], state: Build::BUILDING)
      return render json: { error: "no build of yours by that id" }, status: :not_found if build.nil?

      app = build.mobile_app
      path = params[:kind] == "animation" ? app.splash_animation_path : app.splash_image_path
      return head :no_content if path.blank?

      body, content_type = StorageAccess.new.fetch(domain: build.domain, path: path)
      return head :no_content if body.nil?

      send_data body, type: content_type.presence || "application/octet-stream", disposition: "inline"
    end

    # POST /internal/builds/:id/preview?path=...
    #
    # One file of a static export. The builder holds no Storage credential, so
    # the preview comes back the way the artifact does, and the path is a
    # parameter rather than part of the route because it contains slashes and
    # is somebody else's idea of a filename.
    def preview
      build = Build.find_by(id: params[:id], state: Build::BUILDING)
      return render json: { error: "no build of yours by that id" }, status: :not_found if build.nil?

      relative = params[:path].to_s
      # Anything that could climb out of the preview directory is refused rather
      # than cleaned: a path with .. in it is not a mistake worth guessing at.
      if relative.empty? || relative.include?("..") || relative.start_with?("/")
        return render json: { error: "that is not a path inside the export" }, status: :unprocessable_entity
      end

      body = request.body.read
      return render json: { error: "no file in the request body" }, status: :bad_request if body.to_s.empty?

      StorageAccess.new.store(
        domain: build.domain,
        path: "previews/#{build.mobile_app.bundle_identifier}/#{relative}",
        body: body,
        content_type: request.content_type.presence || "application/octet-stream"
      )

      head :created
    rescue StorageAccess::Refused => e
      render json: { error: e.message }, status: :insufficient_storage
    end

    # POST /internal/builds/:id/artifact
    #
    # The finished app, streamed back rather than uploaded from the builder.
    # The builder runs third-party module code, so it holds no Storage
    # credential: the artifact passes through here, which is also where the
    # quota refusal can be turned into something an operator can act on.
    def artifact
      build = Build.find_by(id: params[:id], state: Build::BUILDING)
      return render json: { error: "no build of yours by that id" }, status: :not_found if build.nil?

      # Handed on as a stream. Reading it here would put the whole APK in this
      # process before Storage had seen a byte of it.
      body = request.body
      return render json: { error: "no artifact in the request body" }, status: :bad_request if empty_body?(body)

      stored = StorageAccess.new.store(
        domain: build.domain,
        path: "apps/#{build.platform}/#{build.mobile_app.bundle_identifier}-#{build.id}#{extension_for(build)}",
        body: body,
        content_type: request.content_type.presence || "application/octet-stream"
      )

      build.record_success!(artifact_path: stored[:path], artifact_bytes: stored[:bytes],
                            duration_ms: params[:duration_ms], log: params[:log])

      render json: { id: build.id, state: build.reload.state, artifact_path: build.artifact_path }
    rescue StorageAccess::Refused => e
      # Storage saying no is not the builder failing. It is a permanent answer
      # for this configuration: another attempt fills the same full disk.
      build.record_failure!(error: "the artifact could not be stored: #{e.message}", permanent: true)
      render json: { error: e.message }, status: :insufficient_storage
    end

    # PATCH /internal/builds/:id
    #
    # One call, one terminal answer. `permanent` is the builder saying this
    # configuration cannot produce an app, which is different from a build that
    # failed and might not next time.
    def update
      build = Build.find_by(id: params[:id], state: Build::BUILDING)
      return render json: { error: "no build of yours by that id" }, status: :not_found if build.nil?

      case params[:outcome]
      when "succeeded"
        build.record_success!(
          artifact_path: params.require(:artifact_path),
          artifact_bytes: params[:artifact_bytes].to_i,
          duration_ms: params[:duration_ms],
          log: params[:log]
        )
      when "failed"
        build.record_failure!(
          error: params[:error].presence || "the builder gave no reason",
          permanent: ActiveModel::Type::Boolean.new.cast(params[:permanent]) == true,
          duration_ms: params[:duration_ms],
          log: params[:log]
        )
      else
        return render json: { error: "outcome must be succeeded or failed" }, status: :unprocessable_entity
      end

      render json: { id: build.id, state: build.reload.state, attempts: build.attempts,
                     next_attempt_at: build.next_attempt_at }
    end

    private

    # Comma separated, and empty means every lane rather than none. A worker
    # that asks for nothing wants anything; a worker that asks for a lane
    # nobody has heard of gets nothing, which is the safe way round.
    def requested_lanes
      named = params[:lanes].to_s.split(",").map(&:strip).reject(&:empty?)
      named.empty? ? nil : named
    end

    # Whether there is anything to store, without consuming the stream.
    # Content-Length is what the sender promised; a Rack input that reports a
    # size of zero has nothing in it either way.
    def empty_body?(io)
      return true if request.content_length.to_i.zero? && !request.headers["Transfer-Encoding"].present?

      io.respond_to?(:size) && io.size.to_i.zero?
    end

    def with_current_secrets(build)
      plan = build.configuration.deep_dup
      app = build.mobile_app

      Array(plan["capabilities"]).each do |capability|
        row = app.app_capabilities.find_by(capability: capability["id"])
        capability["settings"] = row&.settings || {}
      end

      plan
    end

    def extension_for(build)
      build.platform == Build::IOS ? ".zip" : ".apk"
    end
  end
end

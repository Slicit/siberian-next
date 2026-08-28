# frozen_string_literal: true

# The public space, served without a token.
#
# Every other route here proves who is calling before it does anything. This one
# cannot: the caller is a browser loading an image, or a phone rendering a CMS
# block, and neither holds a module token. What makes that safe is the space
# rather than the caller. An object in `public` was put there by a module that
# asked for the public space at install time and had it approved, which is the
# same decision as "anyone may read this".
#
# It exists to take services out of the byte path. Before it, a CMS image on a
# phone was fetched by the Router, proxied whole through the module's own
# process, fetched again through the Router's core door, read whole into the
# Storage service, and only then streamed from Garage: four copies of every
# image, two of them in a language runtime holding the entire file. Now the
# Router asks Storage directly and Storage streams it.
#
# The module is named in the path rather than proved by a token, so the only
# thing this can be pointed at is a public object belonging to some module on
# the domain the Router says the request arrived for. That is exactly the set of
# bytes that were already world-readable.
class PublicFilesController < ApplicationController
  SPACE = "public"

  before_action :require_domain!

  # GET /public/:module_name/*path
  def show
    registration = ModuleRegistration.active.find_by(module_name: params[:module_name])
    return head :not_found if registration.nil?

    # A module that was never granted the public space has nothing here to
    # serve, and saying "not found" rather than "forbidden" avoids confirming
    # which modules exist to somebody guessing names.
    return head :not_found unless registration.allows?(SPACE)

    bucket = BucketProvisioner.new.call(registration, @domain)
    stored, body = ObjectStore.new(bucket).stream(SPACE, path)

    response.headers["Content-Length"] = stored.size.to_s
    response.headers["ETag"] = stored.etag.to_s
    response.headers["Last-Modified"] = stored.last_modified&.httpdate.to_s
    response.headers["Content-Type"] = stored.content_type.presence || "application/octet-stream"
    # Third-party bytes on a core origin. Without both of these a module could
    # upload an HTML file and have it execute as this service.
    response.headers["Content-Disposition"] = "inline"
    response.headers["X-Content-Type-Options"] = "nosniff"
    # Public and immutable enough to cache: a path here is written once by a
    # module that chose the name. Private, per-user data is not in this space.
    response.headers["Cache-Control"] = "public, max-age=300"

    self.response_body = body
  rescue ObjectStore::NotFound
    head :not_found
  rescue ObjectStore::Error, GarageAdmin::Error
    head :bad_gateway
  end

  private

  def path = params[:path].to_s

  def require_domain!
    @domain = request.headers["X-Siberian-Domain"].presence
    return if @domain

    head :bad_request
  end
end

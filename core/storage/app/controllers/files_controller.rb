# frozen_string_literal: true

# The whole module-facing surface of Storage: four verbs and a listing.
#
# No S3, no signature, no SDK. A module in PHP or Python uses whatever HTTP
# client it already has, which is what keeps the module contract independent of
# language.
class FilesController < ApplicationController
  include ModuleAuthentication

  # How long a signed URL lasts unless the module asks for something else.
  # Bounded on both sides: a URL that expires before the browser has followed
  # the redirect is useless, and one that lasts a week is a credential.
  DEFAULT_URL_TTL = 900
  MIN_URL_TTL = 30
  MAX_URL_TTL = 86_400

  before_action :check_space

  # PUT /v1/:space/*path
  def create
    # Both allowances, checked before the bytes go anywhere. The one that
    # refuses is worth naming: "you are full" and "the domain is full" are
    # different problems, with different people to talk to.
    incoming = request.content_length.to_i
    refusal = current_bucket.refusal_for(incoming)
    return render_quota_exceeded(refusal) if refusal

    stored = store.put(space, path, request.body, content_type: request.content_type)
    current_bucket.record_written!(stored.size.to_i)

    render json: {
      path: path, space: space, size: stored.size,
      bucket_remaining_bytes: current_bucket.reload.remaining_bytes,
      domain_remaining_bytes: current_bucket.domain_quota.reload.remaining_bytes
    }, status: :created
  rescue StoredObjects::Error => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /v1/:space/*path
  #
  # Streamed rather than sent whole. `send_data` needs the entire object as a
  # String first, which put every byte of every download into this process's
  # heap: one 67 MB artifact being fetched by three clients was 200 MB of Rails.
  def show
    stored, body = store.stream(space, path)

    response.headers["Content-Length"] = stored.size.to_s
    response.headers["ETag"] = stored.etag.to_s
    response.headers["Last-Modified"] = stored.last_modified&.httpdate.to_s
    response.headers["Content-Type"] = stored.content_type.presence || "application/octet-stream"
    # Third-party bytes served from a core origin. Without this a module can
    # upload an HTML file and have it run as this service.
    response.headers["Content-Disposition"] = "inline"
    response.headers["X-Content-Type-Options"] = "nosniff"

    self.response_body = body
  rescue StoredObjects::NotFound
    render json: { error: "not found" }, status: :not_found
  end

  # GET /v1/urls/:space/*path
  #
  # A signed URL for one of this module's own objects, so the module can send a
  # browser to the object store instead of fetching the file and copying it out
  # of its own process.
  #
  # The authorisation question is the module's, not this service's: only the
  # module knows whether this visitor owns that task. What this guarantees is
  # narrower and is the part worth guaranteeing: the URL is for the calling
  # module's bucket on the calling domain, it reaches exactly one object, and it
  # stops working.
  def signed_url
    ttl = params.fetch(:expires_in, DEFAULT_URL_TTL).to_i.clamp(MIN_URL_TTL, MAX_URL_TTL)

    # A URL for an object that is not there would be a link to an S3 error
    # document, which is a worse answer than saying so now.
    stored = store.head(space, path)

    unless StoredObjects.public_endpoint
      # Nothing to sign against. Saying so is better than returning a URL that
      # names a host only the inside of the stack can reach.
      return render json: { error: "this deployment has no public object store address" },
                    status: :not_implemented
    end

    render json: {
      url: store.presigned_get_url(space, path, expires_in: ttl),
      expires_in: ttl,
      size: stored.size,
      content_type: stored.content_type
    }
  rescue StoredObjects::NotFound
    render json: { error: "not found" }, status: :not_found
  end

  # HEAD /v1/:space/*path
  def describe
    stored = store.head(space, path)
    response.headers["Content-Length"] = stored.size.to_s
    response.headers["ETag"] = stored.etag.to_s
    response.headers["Last-Modified"] = stored.last_modified&.httpdate.to_s
    head :ok
  rescue StoredObjects::NotFound
    head :not_found
  end

  # DELETE /v1/:space/*path
  def destroy
    stored = begin
      store.head(space, path)
    rescue StoredObjects::NotFound
      nil
    end

    store.delete(space, path)
    # Quota is only meaningful if deleting gives the space back, and it has to
    # come back to the domain pool as well as to the bucket.
    current_bucket.record_deleted!(stored.size.to_i) if stored

    head :no_content
  end

  # GET /v1/:space
  def index
    page = store.list(
      space,
      prefix: params[:prefix],
      limit: [params.fetch(:limit, 100).to_i, 1000].min,
      cursor: params[:cursor]
    )
    render json: page
  end

  private

  def space = params[:space]
  def path = params[:path].to_s

  def store
    @store ||= StoredObjects.new(current_bucket)
  end

  def check_space
    unless ModuleRegistration::SPACES.include?(space)
      return render json: { error: "unknown space #{space}" }, status: :not_found
    end

    authorize_space!(space)
  end

  def render_quota_exceeded(reason)
    domain_quota = current_bucket.domain_quota

    render json: {
      error: reason == :domain_full ? "domain quota exceeded" : "bucket quota exceeded",
      reason: reason,
      bucket: {
        quota_mb: current_bucket.quota_mb, bytes_used: current_bucket.bytes_used,
        remaining_bytes: current_bucket.remaining_bytes
      },
      domain: {
        domain: current_domain, quota_mb: domain_quota.quota_mb,
        bytes_used: domain_quota.bytes_used, remaining_bytes: domain_quota.remaining_bytes
      }
    }, status: :insufficient_storage
  end
end

# frozen_string_literal: true

# The whole module-facing surface of Storage: four verbs and a listing.
#
# No S3, no signature, no SDK. A module in PHP or Python uses whatever HTTP
# client it already has, which is what keeps the module contract independent of
# language.
class FilesController < ApplicationController
  include ModuleAuthentication

  before_action :check_space

  # PUT /v1/:space/*path
  def create
    return render_quota_exceeded if current_bucket.over_quota?

    stored = store.put(space, path, request.body, content_type: request.content_type)
    current_bucket.increment!(:bytes_used, stored.size.to_i)

    render json: { path: path, space: space, size: stored.size }, status: :created
  rescue ObjectStore::Error => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /v1/:space/*path
  def show
    body, content_type, length = store.get(space, path)
    response.headers["Content-Length"] = length.to_s
    send_data body, type: content_type.presence || "application/octet-stream", disposition: "inline"
  rescue ObjectStore::NotFound
    render json: { error: "not found" }, status: :not_found
  end

  # HEAD /v1/:space/*path
  def describe
    stored = store.head(space, path)
    response.headers["Content-Length"] = stored.size.to_s
    response.headers["ETag"] = stored.etag.to_s
    response.headers["Last-Modified"] = stored.last_modified&.httpdate.to_s
    head :ok
  rescue ObjectStore::NotFound
    head :not_found
  end

  # DELETE /v1/:space/*path
  def destroy
    stored = begin
      store.head(space, path)
    rescue ObjectStore::NotFound
      nil
    end

    store.delete(space, path)
    # Quota is only meaningful if deleting gives the space back.
    current_bucket.decrement!(:bytes_used, stored.size.to_i) if stored

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
    @store ||= ObjectStore.new(current_bucket)
  end

  def check_space
    unless ModuleRegistration::SPACES.include?(space)
      return render json: { error: "unknown space #{space}" }, status: :not_found
    end

    authorize_space!(space)
  end

  def render_quota_exceeded
    render json: {
      error: "quota exceeded",
      quota_mb: current_module.quota_mb,
      bytes_used: current_bucket.bytes_used
    }, status: :insufficient_storage
  end
end

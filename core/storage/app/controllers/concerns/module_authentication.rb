# frozen_string_literal: true

# Establishes which module is calling, and for which domain.
#
# Neither is a request parameter. The module proves itself with the token the
# Orchestrator issued at install time, and the domain arrives as the header the
# Router sets. A module therefore has no field in which to name another module's
# files, or another domain's.
module ModuleAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_module!
    before_action :require_domain!
  end

  private

  attr_reader :current_module, :current_domain

  def authenticate_module!
    @current_module = ModuleRegistration.authenticate(bearer_token)
    return if @current_module

    render json: { error: "unknown or revoked module token" }, status: :unauthorized
  end

  def require_domain!
    @current_domain = request.headers["X-Siberian-Domain"].presence
    return if @current_domain

    render json: { error: "X-Siberian-Domain is required; the Router sets it" },
           status: :bad_request
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    return nil unless header.start_with?("Bearer ")

    header.delete_prefix("Bearer ").strip
  end

  def current_bucket
    @current_bucket ||= BucketProvisioner.new.call(current_module, current_domain)
  end

  def authorize_space!(space)
    return true if current_module.allows?(space)

    render json: { error: "this module was not granted the #{space} space" }, status: :forbidden
    false
  end
end

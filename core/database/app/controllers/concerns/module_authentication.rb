# frozen_string_literal: true

# Establishes which module is calling, and for which domain. Neither is a
# request parameter: the token proves the module, the Router supplies the
# domain. A module has no field in which to name another module's database.
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

    render json: { error: "X-Siberian-Domain is required; the Router sets it" }, status: :bad_request
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    return nil unless header.start_with?("Bearer ")

    header.delete_prefix("Bearer ").strip
  end
end

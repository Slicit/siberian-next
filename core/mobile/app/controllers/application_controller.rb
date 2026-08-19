# frozen_string_literal: true

class ApplicationController < ActionController::API
  private

  # The Orchestrator, holding the token every core service shares.
  def authenticate_admin!
    return if constant_compare(bearer_token, ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only"))

    render json: { error: "admin token required" }, status: :unauthorized
  end

  # The builder, which is a different trust level and therefore a different
  # token. It runs third-party module code, so it gets what one claimed build
  # needs and nothing else: no catalogue, no other domain, no other app.
  def authenticate_builder!
    return if constant_compare(bearer_token, ENV.fetch("SIBERIAN_BUILDER_TOKEN", "builder_dev_only"))

    render json: { error: "builder token required" }, status: :unauthorized
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    return "" unless header.start_with?("Bearer ")

    header.delete_prefix("Bearer ").strip
  end

  def constant_compare(given, expected)
    ActiveSupport::SecurityUtils.secure_compare(given.to_s, expected.to_s)
  end
end

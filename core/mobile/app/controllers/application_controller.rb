# frozen_string_literal: true

class ApplicationController < ActionController::API
  private

  # A core service that is allowed to be here, which in practice is the
  # Orchestrator. Identified rather than merely admitted: these endpoints used
  # to accept the one token every service shared, so "who registered this
  # module" had no answer.
  def authenticate_admin!
    caller_name = Siberian::ServiceIdentity.identify(bearer_token)

    if caller_name == Siberian::ServiceIdentity::LEGACY
      Rails.logger.warn("#{self.class.name}: accepted the shared admin token. Set SIBERIAN_CALLERS.")
      @calling_service = "unverified"
      return
    end

    return render json: { error: "core services only" }, status: :unauthorized if caller_name.nil?

    unless permitted_callers.include?(caller_name)
      Rails.logger.warn("#{self.class.name}: refused #{caller_name}")
      return render json: { error: "#{caller_name} is not permitted here" }, status: :unauthorized
    end

    @calling_service = caller_name
  end

  # Overridden by a controller that admits somebody else. Named here rather
  # than left implicit so that adding a caller is a visible edit.
  def permitted_callers = %w[orchestrator]

  attr_reader :calling_service

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

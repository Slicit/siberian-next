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

  # Callers that speak for one domain rather than for the system.
  #
  # The Backoffice is run by an operator and legitimately sees every domain. The
  # Base App is inside one, and whoever is looking at it has no business seeing
  # another domain's builds. So a pinned caller must always name a domain, and
  # never gets the view across all of them.
  #
  # What this does not do, and cannot from here: stop a pinned caller naming a
  # domain that is not its own. The Base App reaches this service directly, so
  # the domain is claimed rather than asserted by the Router. Closing that means
  # routing core to core calls through the Router so it stamps the domain, which
  # is a wider change and is deliberately not made here.
  #
  # The trust that remains is therefore explicit: a compromised Base App can
  # name another domain. An uncompromised one cannot do so by accident, which is
  # the failure this actually prevents.
  PINNED_CALLERS = %w[base].freeze

  def pinned_caller? = PINNED_CALLERS.include?(calling_service)

  # A pinned caller with no domain is a bug in the caller, not a request for
  # everything, and answering it with everything is how the bug would go
  # unnoticed.
  def require_named_domain!
    return unless pinned_caller?
    return if params[:domain].present?

    render json: { error: "this caller must name the domain it is acting for" },
           status: :bad_request
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

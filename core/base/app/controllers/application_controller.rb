# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # No allow_browser guard: it answers an unrecognised User-Agent with 403,
  # which catches health checks and anything relaying a request.

  before_action :require_user!

  helper_method :current_user, :current_domain, :directory, :allow?

  private

  def current_domain
    @current_domain ||= request.headers["X-Siberian-Domain"].presence ||
                        ENV["SIBERIAN_DOMAIN"].presence ||
                        request.host
  end

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = Siberian::AuthClient.new.identify(cookies[:siberian_session])
  end

  def allow?(permission)
    current_user&.allow?(permission) || false
  end

  def require_user!
    return redirect_to("/login?return_to=#{CGI.escape(request.original_url)}", allow_other_host: true) unless current_user

    # Signed in is not the same as allowed in. Somebody with an account but no
    # app.use is told so rather than shown an empty product.
    render "shared/no_access", status: :forbidden unless allow?("app.use")
  end

  # What this person may open. The shell asks once and filters, rather than
  # rendering a sidebar of things that answer 403.
  def visible_capabilities(capabilities)
    capabilities.select { |capability| allow?("module.#{capability.module_name}.use") }
  end

  def directory
    @directory ||= CapabilityDirectory.new
  end
end

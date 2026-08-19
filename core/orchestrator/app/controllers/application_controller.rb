# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # No allow_browser guard. It answers an unrecognised User-Agent with 403,
  # which catches health checks and anything relaying a request.

  before_action :require_operator!

  helper_method :current_user, :current_domain, :catalog

  private

  def current_domain
    @current_domain ||= request.headers["X-Siberian-Domain"].presence ||
                        ENV["SIBERIAN_DOMAIN"].presence ||
                        request.host
  end

  # The Backoffice holds no password. It forwards the browser cookie to the one
  # service that can read it, exactly as a module does.
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = AuthClient.new.identify(cookies[:siberian_session])
  end

  # A signed-in user who is not an operator is told so plainly, rather than
  # shown a login form they have already completed.
  def require_operator!
    return if current_user&.operator?

    if current_user
      render "shared/not_an_operator", status: :forbidden
    else
      redirect_to login_url_for(request.original_url), allow_other_host: true
    end
  end

  # Sign-in lives on the main domain, because that is where the cookie has to
  # be set for every module frame to carry it.
  def login_url_for(return_to)
    domain = current_domain.to_s.delete_prefix("admin.")
    "#{request.scheme}://#{domain}/login?return_to=#{CGI.escape(return_to)}"
  end

  def catalog
    @catalog ||= ModuleCatalog.new
  end

  def driver
    @driver ||= Siberian::Engine.driver
  end
end

# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # No allow_browser guard: it answers an unrecognised User-Agent with 403,
  # which catches health checks and anything relaying a request.

  before_action :require_user!

  helper_method :current_user, :current_domain, :directory

  private

  def current_domain
    @current_domain ||= request.headers["X-Siberian-Domain"].presence ||
                        ENV["SIBERIAN_DOMAIN"].presence ||
                        request.host
  end

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = AuthClient.new.identify(cookies[:siberian_session])
  end

  def require_user!
    return if current_user

    redirect_to "/login?return_to=#{CGI.escape(request.original_url)}", allow_other_host: true
  end

  def directory
    @directory ||= CapabilityDirectory.new
  end
end

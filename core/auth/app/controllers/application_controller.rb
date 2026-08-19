# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # No allow_browser guard. It answers an unrecognised User-Agent with 403,
  # which catches every non-browser caller: health checks, the test suite, and
  # any service relaying a request. Browser support is a product decision, not
  # something to enforce at the door of an authentication service.

  helper_method :current_user, :current_session, :current_domain

  private

  # The domain travels on every request from the Router. Falling back to the
  # request host keeps direct access working in development, where there is no
  # Router in front.
  def current_domain
    @current_domain ||= request.headers["X-Siberian-Domain"].presence ||
                        ENV["SIBERIAN_DOMAIN"].presence ||
                        request.host
  end

  def current_session
    return @current_session if defined?(@current_session)

    @current_session = Session.authenticate(cookies[SessionsController::COOKIE])
  end

  def current_user
    current_session&.user
  end

  def require_user!
    return if current_user

    redirect_to login_path(return_to: request.original_url)
  end
end

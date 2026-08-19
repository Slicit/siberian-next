# frozen_string_literal: true

class ApplicationController < ActionController::Base
  allow_browser versions: :modern

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

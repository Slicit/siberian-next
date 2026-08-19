# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # No allow_browser guard. It answers an unrecognised User-Agent with 403,
  # which catches health checks and anything relaying a request.

  before_action :require_signed_in!

  helper_method :current_user, :current_domain, :catalog, :allow?

  # Declares what a controller needs, checked before every action in it.
  #
  # A before_action rather than a check inside each method, because the failure
  # mode of the second is a method somebody forgets, and that method is the one
  # that matters.
  def self.requires(permission, **options)
    before_action(**options) { require_permission!(permission) }
  end

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

    @current_user = auth.identify(cookies[:siberian_session])
  end

  def auth
    @auth ||= Siberian::AuthClient.new
  end

  # Every check after the first is a set lookup on a resolved answer, which is
  # why a page can ask a dozen times without anybody noticing.
  def allow?(permission)
    current_user&.allow?(permission) || false
  end

  # Anybody signed in may reach the Backoffice; what they can see once inside is
  # decided per controller. Somebody with no operator permission at all sees a
  # page saying so rather than a login form they have already completed.
  def require_signed_in!
    return if current_user

    redirect_to login_url_for(request.original_url), allow_other_host: true
  end

  def require_permission!(permission)
    return if allow?(permission)

    @missing_permission = permission
    render "shared/not_permitted", status: :forbidden
  end

  # For the few actions where a cached answer is not good enough: removing a
  # module, changing who can do what. Costs a round trip, and is worth it
  # exactly where it is used.
  def require_fresh_permission!(permission)
    return if auth.authorize?(cookies[:siberian_session], permission)

    @missing_permission = permission
    render "shared/not_permitted", status: :forbidden
  end

  def login_url_for(return_to)
    domain = current_domain.to_s.delete_prefix("core.")
    "#{request.scheme}://#{domain}/login?return_to=#{CGI.escape(return_to)}"
  end

  def catalog
    @catalog ||= ModuleCatalog.new
  end

  def driver
    @driver ||= Siberian::Engine.driver
  end
end

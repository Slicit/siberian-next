# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # No allow_browser guard: it answers an unrecognised User-Agent with 403,
  # which catches health checks and anything relaying a request.

  before_action :require_user!

  # The menu is on every page, so it is loaded for every page rather than by
  # each controller that happens to remember. It was the second: the phone app
  # page did not set it, and the layout tolerated the absence with `@groups ||
  # []`, so the modules simply disappeared from the menu on that one page and
  # nothing anywhere reported a thing.
  before_action :load_menu

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

  # Never fatal. A shell that will not render because the directory is briefly
  # unreachable is worse than one with an empty menu and a page that works.
  def load_menu
    @groups = directory.grouped(domain: current_domain, only: method(:visible_capabilities)) || []
  rescue StandardError => e
    Rails.logger.warn("could not load the menu: #{e.message}")
    @groups = []
  end

  def directory
    @directory ||= CapabilityDirectory.new
  end
end

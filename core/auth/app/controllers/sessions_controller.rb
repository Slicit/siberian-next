# frozen_string_literal: true

# The one login screen in the system.
#
# The cookie it sets is scoped to the parent domain, so every module frame at
# <module>.apps.<domain> carries it. That is what lets a module identify the
# signed-in user without implementing, or ever seeing, a login.
class SessionsController < ApplicationController
  COOKIE = :siberian_session

  allow_browser versions: :modern, only: []

  def new
    redirect_to(safe_return_to || root_path) if current_session
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)

    # One message for both failures. Telling an attacker which half was wrong
    # turns a password guess into an account enumeration.
    unless user&.authenticate(params[:password])
      flash.now[:alert] = "That email and password do not match."
      return render :new, status: :unprocessable_entity
    end

    session_record, token = Session.start!(
      user: user,
      domain: current_domain,
      user_agent: request.user_agent,
      ip_address: request.remote_ip
    )
    user.update_column(:last_seen_at, Time.current)

    set_session_cookie(token, session_record.expires_at)
    redirect_to safe_return_to || root_path
  end

  def destroy
    current_session&.revoke!
    cookies.delete(COOKIE, domain: cookie_domain)
    redirect_to login_path, notice: "Signed out."
  end

  private

  def set_session_cookie(token, expires_at)
    cookies[COOKIE] = {
      value: token,
      domain: cookie_domain,
      expires: expires_at,
      httponly: true,
      secure: request.ssl?,
      # Lax would drop the cookie on the top-level navigation into a module
      # origin. None needs Secure, which development over plain HTTP does not
      # have, so the strictest workable value is chosen per request.
      same_site: request.ssl? ? :none : :lax
    }
  end

  # A leading dot covers every subdomain, which is how module origins arrive.
  def cookie_domain
    ".#{current_domain}"
  end

  # Never redirect to somewhere the request asked for without checking it: an
  # open redirect on a login form is how a phishing page borrows your domain.
  def safe_return_to
    target = params[:return_to].to_s
    return nil if target.blank?

    uri = URI.parse(target)
    return target if uri.host.nil? && target.start_with?("/")
    return target if uri.host.to_s == current_domain || uri.host.to_s.end_with?(".#{current_domain}")

    nil
  rescue URI::InvalidURIError
    nil
  end
end

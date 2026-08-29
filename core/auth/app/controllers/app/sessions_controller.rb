# frozen_string_literal: true

# Sign in, sign up, and sign out for the people an app is for.
#
# JSON rather than a form, because the caller is a phone rather than a browser,
# and it hands back a bearer token the app stores. It also sets the same cookie
# the browser login sets, for one reason: a module rendered in a WebView reads
# that cookie to know who is in front of it, and asking every module to
# understand a second scheme would be asking every module author to reimplement
# the thing the core exists to provide.
#
# So one sign-in produces both. The token is what the app holds; the cookie is
# what the pages it frames carry.
module App
  class SessionsController < ActionController::API
    include ActionController::Cookies

    # POST /-/auth/register
    def create_account
      settings = AppSetting.for(current_domain)

      unless settings.registration_open
        # Not 404. An operator turning this on is the fix, and a caller that
        # cannot tell "closed" from "broken" cannot say so.
        return render json: { error: "registration is closed for this domain" },
                      status: :forbidden
      end

      account = AppUser.new(
        domain: current_domain,
        email: params[:email],
        name: params[:name],
        password: params[:password]
      )

      unless account.save
        # An email already taken on this domain is reported as such rather than
        # hidden. Signup is where somebody finds out they already have an
        # account, and a generic failure there sends them to support instead.
        return render json: { error: account.errors.full_messages.to_sentence },
                      status: :unprocessable_entity
      end

      issue(account)
    end

    # POST /-/auth/sign-in
    def create
      email = params[:email].to_s.strip.downcase

      # Before the password is checked, not after. bcrypt is deliberately slow,
      # which makes an unthrottled sign-in a way to spend this box's CPU as well
      # as a way to guess a password.
      if AuthAttempt.exhausted?(kind: AuthAttempt::SIGN_IN, identifier: email,
                                ip_address: request.remote_ip)
        return render json: { error: "too many attempts, try again later" },
                      status: :too_many_requests
      end

      account = AppUser.on(current_domain).find_by(email: email)

      # One message for both failures, and for a deactivated account. Telling a
      # caller which half was wrong turns a password guess into a way to find
      # out who has an account on this domain.
      unless account&.active? && account.authenticate(params[:password])
        AuthAttempt.record!(kind: AuthAttempt::SIGN_IN, identifier: email,
                            domain: current_domain, ip_address: request.remote_ip)
        return render json: { error: "that email and password do not match" },
                      status: :unauthorized
      end

      # Cleared on success, so somebody who mistyped three times and then got it
      # right is not most of the way to a lockout.
      AuthAttempt.forget!(kind: AuthAttempt::SIGN_IN, identifier: email)
      issue(account)
    end

    # GET /-/auth/me
    def show
      session_record = authenticated
      return render json: { authenticated: false }, status: :unauthorized unless session_record

      session_record.touch_seen!

      render json: {
        authenticated: true,
        user: session_record.app_user.to_identity,
        device: session_record.to_device,
        expires_at: session_record.expires_at
      }
    end

    # GET /-/auth/devices
    #
    # Every device this account is signed in on, so somebody can see the list
    # and end the one they no longer have.
    def devices
      session_record = authenticated
      return render json: { error: "not signed in" }, status: :unauthorized unless session_record

      render json: {
        devices: session_record.app_user.app_sessions.active.recent.map do |device|
          device.to_device.merge(current: device.id == session_record.id)
        end
      }
    end

    # DELETE /-/auth/devices/:id
    def revoke_device
      session_record = authenticated
      return render json: { error: "not signed in" }, status: :unauthorized unless session_record

      device = session_record.app_user.app_sessions.active.find_by(id: params[:id])
      return render json: { error: "no device of yours by that id" }, status: :not_found if device.nil?

      device.revoke!
      # Ending the session making the request is a sign-out, and the cookie has
      # to go with it or the browser keeps presenting a token that is dead.
      forget_cookie if device.id == session_record.id

      render json: { revoked: device.id, signed_out: device.id == session_record.id }
    end

    # DELETE /-/auth/sign-out
    #
    # This device only. Ending every session because somebody signed out on one
    # phone would be a surprise, and the device list is where "all of them"
    # belongs.
    def destroy
      authenticated&.revoke!
      forget_cookie
      head :no_content
    end

    private

    def issue(account)
      session_record, token = AppSession.start!(
        app_user: account,
        device_id: params[:device_id],
        device_name: params[:device_name],
        platform: params[:platform],
        user_agent: request.user_agent,
        ip_address: request.remote_ip
      )
      account.update_columns(last_seen_at: Time.current, updated_at: Time.current)

      set_cookie(token, session_record.expires_at)

      render json: {
        token: token,
        expires_at: session_record.expires_at,
        user: account.to_identity,
        device: session_record.to_device
      }, status: :created
    end

    def authenticated
      AppSession.authenticate(bearer_token || cookies[::SessionsController::COOKIE])
    end

    # The app holds a token and sends it as a bearer; the WebView pages it
    # frames send the cookie. Both are the same opaque string.
    def bearer_token
      header = request.headers["Authorization"].to_s
      header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip.presence : nil
    end

    def set_cookie(token, expires_at)
      cookies[::SessionsController::COOKIE] = {
        value: token,
        domain: ".#{current_domain}",
        expires: expires_at,
        httponly: true,
        secure: request.ssl?,
        same_site: request.ssl? ? :none : :lax
      }
    end

    def forget_cookie
      cookies.delete(::SessionsController::COOKIE, domain: ".#{current_domain}")
    end

    def current_domain
      @current_domain ||= request.headers["X-Siberian-Domain"].presence ||
                          ENV["SIBERIAN_DOMAIN"].presence ||
                          request.host
    end
  end
end

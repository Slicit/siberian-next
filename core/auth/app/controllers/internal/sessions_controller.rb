# frozen_string_literal: true

# How everything else in the system asks who is signed in.
#
# The Base App calls it to render a shell, and a module calls it to identify
# the person in front of it. Neither implements a login, and neither ever sees
# a password.
module Internal
  class SessionsController < ActionController::API
    # GET /internal/session
    #
    # The caller forwards the browser's cookie. A module can therefore learn who
    # the user is without being trusted with anything: the cookie proves the
    # session, and this service is the only thing that can read it.
    def show
      session_record = Session.authenticate(token_from_request)

      unless session_record
        return render json: { authenticated: false }, status: :unauthorized
      end

      render json: {
        authenticated: true,
        user: session_record.user.to_identity,
        expires_at: session_record.expires_at
      }
    end

    # DELETE /internal/session
    def destroy
      Session.authenticate(token_from_request)&.revoke!
      head :no_content
    end

    private

    # Either the cookie a browser sent, or an explicit header for a service that
    # is relaying one. Both carry the same opaque token.
    def token_from_request
      request.headers["X-Siberian-Session"].presence ||
        cookies[SessionsController::COOKIE].presence
    end
  end
end

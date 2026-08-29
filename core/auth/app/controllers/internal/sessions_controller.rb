# frozen_string_literal: true

# How everything else in the system asks who is signed in, and what they may do.
#
# The Base App calls it to render a shell, the Backoffice to decide whether to
# let somebody in, and a module to identify the person in front of it. None of
# them implements a login, and none of them ever sees a password.
module Internal
  class SessionsController < ActionController::API
    # API controllers ship without a cookie jar, and this endpoint exists to read
    # the browser cookie a caller forwarded.
    include ActionController::Cookies

    # GET /internal/session
    #
    # One row read and, only when the version stamp says the answer is stale, one
    # re-resolution. Everything the caller asks afterwards is a set lookup on
    # their side, which is the entire performance argument for resolving here.
    def show
      session_record = Session.authenticate(token_from_request)

      # A core account, resolved the expensive way once and cached on the row.
      if session_record
        permissions = session_record.permission_set

        return render json: {
          authenticated: true,
          user: session_record.user.to_identity(permissions),
          permissions: permissions.to_a,
          denied: permissions.denied,
          permissions_version: session_record.permissions_version,
          expires_at: session_record.expires_at
        }
      end

      # An app account. The same shape, so a module identifying the person in
      # front of it does not have to know which kind it got: it asks what they
      # may do and gets an answer either way. The permission set is fixed rather
      # than resolved, which is why there is no version stamp to report.
      app_record = AppSession.authenticate(token_from_request)

      unless app_record
        return render json: { authenticated: false }, status: :unauthorized
      end

      app_record.touch_seen!
      permissions = app_record.app_user.permission_set

      render json: {
        authenticated: true,
        user: app_record.app_user.to_identity,
        permissions: permissions.to_a,
        denied: permissions.denied,
        permissions_version: 0,
        expires_at: app_record.expires_at
      }
    end

    # POST /internal/authorize
    #
    # A fresh answer for one question, bypassing any cache the caller holds.
    #
    # Callers cache the resolved set for a short window, which means a withdrawn
    # permission can survive that window. For most of a page that is the right
    # trade. For the handful of actions where it is not, this exists.
    def authorize_action
      permission = params.require(:permission)
      session_record = Session.authenticate(token_from_request)

      if session_record
        # Deliberately re-resolves rather than trusting the stored copy: the
        # point of this endpoint is to be right, not to be quick.
        permissions = session_record.refresh_permissions!

        return render json: {
          allowed: permissions.allow?(permission),
          permission: permission,
          user: session_record.user.email
        }
      end

      app_record = AppSession.authenticate(token_from_request)

      unless app_record
        return render json: { allowed: false, reason: "no session" }, status: :unauthorized
      end

      # Nothing to re-resolve: an app account holds a fixed set, so the stored
      # copy and the fresh one are the same answer by construction.
      render json: {
        allowed: app_record.app_user.permission_set.allow?(permission),
        permission: permission,
        user: app_record.app_user.email
      }
    end

    # DELETE /internal/session
    def destroy
      token = token_from_request
      (Session.authenticate(token) || AppSession.authenticate(token))&.revoke!
      head :no_content
    end

    private

    # Either the cookie a browser sent, or an explicit header for a service that
    # is relaying one. Both carry the same opaque token.
    def token_from_request
      request.headers["X-Siberian-Session"].presence ||
        # Rooted, because inside module Internal a bare SessionsController
        # resolves to Internal::SessionsController, which has no cookie name.
        cookies[::SessionsController::COOKIE].presence
    end
  end
end

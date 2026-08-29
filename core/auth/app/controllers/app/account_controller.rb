# frozen_string_literal: true

# What a person can do to their own account without asking anybody.
#
# Everything here was possible for an operator and impossible for the person it
# belongs to, which is the wrong way round for a product whose audience is the
# app user. Changing a password meant asking for a reset link to an address you
# were already signed in with; changing a name meant asking an operator; and
# ending an account meant asking somebody to do it for you.
module App
  class AccountController < ActionController::API
    include ActionController::Cookies

    before_action :require_account

    # PATCH /-/auth/me
    def update
      @account.name = params[:name] if params.key?(:name)

      if @account.save
        render json: { user: @account.to_identity }
      else
        render json: { error: @account.errors.full_messages.to_sentence },
               status: :unprocessable_entity
      end
    end

    # POST /-/auth/password
    #
    # The current password, even though they are signed in. A session left open
    # on a borrowed laptop is the case this is for: whoever is holding it can
    # already read everything, and the one thing they must not be able to do is
    # take the account.
    def change_password
      unless @account.authenticate(params[:current_password].to_s)
        return render json: { error: "that is not the current password" }, status: :unauthorized
      end

      @account.password = params[:password]

      unless @account.save
        return render json: { error: @account.errors.full_messages.to_sentence },
                      status: :unprocessable_entity
      end

      # Every other device, and not this one. Somebody changing a password
      # because they think somebody else has it wants the others gone; being
      # signed out of the phone in their hand as well is a surprise.
      other_devices.each(&:revoke!)

      render json: { changed: true, signed_out_elsewhere: true, user: @account.to_identity }
    end

    # POST /-/auth/sign-out-everywhere
    #
    # Including this device. That is the difference from the line above: this is
    # the deliberate "I have lost track of where I am signed in" action.
    def sign_out_everywhere
      count = @account.app_sessions.active.count
      @account.app_sessions.active.find_each(&:revoke!)
      forget_cookie

      render json: { signed_out: count }
    end

    # DELETE /-/auth/me
    #
    # Final, and the person is told exactly what it does and does not do.
    def destroy
      unless @account.authenticate(params[:password].to_s)
        return render json: { error: "that is not the password" }, status: :unauthorized
      end

      @account.erase!
      forget_cookie

      render json: {
        deleted: true,
        # Said plainly rather than implied. Modules hold their own rows and the
        # core cannot reach into them, which is the same isolation that keeps a
        # module out of everybody else's data.
        note: "You can no longer sign in and every device has been signed out. " \
              "Anything you created inside a module is held by that module and is " \
              "not removed by this. Your address stays claimed so that nobody else " \
              "can be given what you left behind."
      }
    end

    private

    def require_account
      @session = AppSession.authenticate(bearer_token || cookies[::SessionsController::COOKIE])
      return render json: { error: "not signed in" }, status: :unauthorized unless @session

      @account = @session.app_user
    end

    def other_devices
      @account.app_sessions.active.where.not(id: @session.id)
    end

    def bearer_token
      header = request.headers["Authorization"].to_s
      header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip.presence : nil
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

# frozen_string_literal: true

# A way back in for somebody who cannot sign in.
#
# The whole endpoint is public and unauthenticated, which is what it is for and
# also what makes it the most abusable thing in the system: it sends an email to
# any address on request. So it is throttled, it says the same thing whether or
# not the account exists, and it hands the actual sending to the Mailer, where a
# failure is queued and visible rather than lost.
module App
  class PasswordsController < ActionController::API
    include ActionController::Cookies

    # POST /-/auth/forgot
    def create
      email = params[:email].to_s.strip.downcase

      if AuthAttempt.exhausted?(kind: AuthAttempt::RESET, identifier: email,
                                ip_address: request.remote_ip)
        # Said plainly rather than disguised as success. A person who genuinely
        # asked three times needs to know that waiting is the answer, and an
        # attacker learns only that the endpoint has a limit, which they were
        # going to find out anyway.
        return render json: { error: "too many reset requests, try again later" },
                      status: :too_many_requests
      end

      AuthAttempt.record!(kind: AuthAttempt::RESET, identifier: email,
                          domain: current_domain, ip_address: request.remote_ip)

      account = AppUser.on(current_domain).active.find_by(email: email)
      send_reset(account) if account

      # The same answer either way, always.
      #
      # Anything else turns this into a way to ask whether an address has an
      # account on this domain, which is exactly the question the per-domain
      # design makes worth asking: knowing somebody is a customer here is
      # itself the leak.
      render json: { sent: true,
                     message: "if that address has an account, a reset link is on its way" }
    end

    # GET /-/auth/reset?token=...
    #
    # Whether a link is still good, so an app can say so before showing a form
    # rather than after somebody has typed a new password twice.
    def show
      _, reason = AppPasswordReset.claim(params[:token])

      if reason == :ok
        render json: { valid: true }
      else
        render json: { valid: false, reason: reason }, status: :unprocessable_entity
      end
    end

    # POST /-/auth/reset
    def update
      reset, reason = AppPasswordReset.claim(params[:token])

      unless reset
        return render json: { error: message_for(reason), reason: reason },
                      status: :unprocessable_entity
      end

      unless reset.complete!(params[:password])
        return render json: { error: reset.app_user.errors.full_messages.to_sentence },
                      status: :unprocessable_entity
      end

      # Whoever just proved they can read the mailbox is signed in. Making them
      # type the password they set ten seconds ago is ceremony, and the cookie
      # every other sign-in leaves is what a WebView needs anyway.
      AuthAttempt.forget!(kind: AuthAttempt::SIGN_IN, identifier: reset.app_user.email)
      issue_session(reset.app_user)
    end

    private

    def send_reset(account)
      reset, token = AppPasswordReset.start!(account, requested_ip: request.remote_ip)

      link = "https://#{current_domain}/-/auth/reset?token=#{token}"

      Siberian::CoreMailClient.new(logger: Rails.logger).deliver(
        domain: current_domain,
        to: account.email,
        subject: "Reset your password",
        text_body: <<~BODY,
          Somebody asked to reset the password for #{account.email} on #{current_domain}.

          #{link}

          The link works once and stops working #{AppPasswordReset::LIFETIME.inspect} from now.
          If this was not you, nothing has changed and you can ignore this.
        BODY
        # One email per reset row rather than per request. A caller retrying
        # after a timeout should not send a second copy of a link that is
        # already in flight.
        idempotency_key: "app-password-reset-#{reset.id}"
      )
    end

    def issue_session(account)
      session_record, token = AppSession.start!(
        app_user: account,
        device_id: params[:device_id], device_name: params[:device_name],
        platform: params[:platform],
        user_agent: request.user_agent, ip_address: request.remote_ip
      )

      cookies[::SessionsController::COOKIE] = {
        value: token, domain: ".#{current_domain}", expires: session_record.expires_at,
        httponly: true, secure: request.ssl?,
        same_site: request.ssl? ? :none : :lax
      }

      render json: {
        token: token,
        expires_at: session_record.expires_at,
        user: account.to_identity,
        device: session_record.to_device
      }, status: :created
    end

    def message_for(reason)
      case reason
      when :expired then "that link has expired, ask for another"
      when :used then "that link has already been used"
      else "that link is not valid"
      end
    end

    def current_domain
      @current_domain ||= request.headers["X-Siberian-Domain"].presence ||
                          ENV["SIBERIAN_DOMAIN"].presence ||
                          request.host
    end
  end
end

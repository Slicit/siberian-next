# frozen_string_literal: true

# Getting back into a core account.
#
# A browser flow rather than the JSON one app accounts use, because this is the
# same door as the sign-in form and the person is looking at a page.
#
# The app version came first, because an app account had no other way in at all.
# A core account has an operator who can reset it by hand, which made this less
# urgent and not less necessary: the installation with one operator has nobody
# to ask.
class PasswordsController < ApplicationController
  # GET /forgot
  def new; end

  # POST /forgot
  def create
    email = params[:email].to_s.strip.downcase

    if AuthAttempt.exhausted?(kind: AuthAttempt::RESET, identifier: email,
                              ip_address: request.remote_ip)
      flash.now[:alert] = "That has been asked for a few times already. Try again later."
      return render :new, status: :too_many_requests
    end

    AuthAttempt.record!(kind: AuthAttempt::RESET, identifier: email,
                        domain: current_domain, ip_address: request.remote_ip)

    user = User.active.find_by(email: email)
    send_reset(user) if user

    # The same answer either way. Anything else turns this into a way to ask
    # whether an address has an account here.
    redirect_to login_path,
                notice: "If that address has an account, a reset link is on its way."
  end

  # GET /reset?token=...
  def edit
    @token = params[:token].to_s
    _, reason = UserPasswordReset.claim(@token)
    return if reason == :ok

    redirect_to forgot_path, alert: UserPasswordReset.message_for(reason)
  end

  # POST /reset
  def update
    @token = params[:token].to_s
    reset, reason = UserPasswordReset.claim(@token)

    return redirect_to forgot_path, alert: UserPasswordReset.message_for(reason) unless reset

    if params[:password] != params[:password_confirmation]
      flash.now[:alert] = "Those two passwords are not the same."
      return render :edit, status: :unprocessable_entity
    end

    unless reset.complete!(params[:password])
      flash.now[:alert] = reset.user.errors.full_messages.to_sentence.presence ||
                          "That password was refused."
      return render :edit, status: :unprocessable_entity
    end

    # Whoever proved they can read the mailbox is signed in. Making them type
    # the password they set ten seconds ago is ceremony.
    AuthAttempt.forget!(kind: AuthAttempt::SIGN_IN, identifier: reset.user.email)
    session_record, token = Session.start!(
      user: reset.user, domain: current_domain,
      user_agent: request.user_agent, ip_address: request.remote_ip
    )
    set_session_cookie(token, session_record.expires_at)

    redirect_to root_path, notice: "Your password is set, and every other session has been ended."
  end

  private

  def send_reset(user)
    reset, token = UserPasswordReset.start!(user, requested_ip: request.remote_ip)

    Siberian::CoreMailClient.new(logger: Rails.logger).deliver(
      domain: current_domain,
      to: user.email,
      subject: "Reset your password",
      text_body: <<~BODY,
        Somebody asked to reset the password for #{user.email} on #{current_domain}.

        #{reset_url(token: token, host: current_domain, protocol: "https")}

        The link works once and stops working two hours from now. Using it also
        signs you out everywhere else.

        If this was not you, nothing has changed and you can ignore this.
      BODY
      # One email per reset row rather than per request, so a caller retrying
      # after a timeout does not send a second copy of a link already in flight.
      idempotency_key: "user-password-reset-#{reset.id}"
    )
  end

  def set_session_cookie(token, expires_at)
    cookies[SessionsController::COOKIE] = {
      value: token,
      domain: ".#{current_domain}",
      expires: expires_at,
      httponly: true,
      secure: request.ssl?,
      same_site: request.ssl? ? :none : :lax
    }
  end
end

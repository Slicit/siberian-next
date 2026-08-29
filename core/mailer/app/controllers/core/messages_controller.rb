# frozen_string_literal: true

# Mail sent by the core itself.
#
# The Mailer was built for modules, and every message hung off a module
# registration. Auth is the first thing in the core that needs to send
# somebody an email, and registering it as a module would have cost nothing and
# been wrong: "module" means the packaged third-party unit everywhere else here.
#
# So this is the same queue, the same retry, the same transport interface, and
# a different kind of sender. The caller proves itself with the per-pair service
# token every core service already holds, rather than with a module token it has
# no business having.
module Core
  class MessagesController < ActionController::API
    include Siberian::ServiceAuthentication

    # Auth, and nothing else, until something else has a reason. Forgetting to
    # widen this refuses a caller loudly; widening it by default would let any
    # compromised core service send mail as the core.
    # Auth sends a way back into an account. The Orchestrator sends an alert to
    # whoever can act on it. Nothing else has a reason, and widening this by
    # default would let any compromised core service send mail as the core.
    permit_services :auth, :orchestrator

    # POST /core/messages
    def create
      domain = params[:domain].to_s.strip.downcase
      return render json: { error: "domain is required" }, status: :bad_request if domain.blank?

      key = params[:idempotency_key].presence

      # The same guarantee a module gets. A caller retrying after a timeout
      # cannot tell whether the first request landed, and somebody receiving two
      # password reset emails for one click will reasonably assume they were
      # attacked.
      if key && (existing = Message.find_by(core_sender: sender, idempotency_key: key))
        return render json: existing.summary.merge(deduplicated: true), status: :ok
      end

      message = Message.new(
        core_sender: sender,
        domain: domain,
        to: params[:to], cc: params[:cc], bcc: params[:bcc],
        from: params[:from], reply_to: params[:reply_to],
        subject: params[:subject],
        text_body: params[:text_body], html_body: params[:html_body],
        headers: params[:headers]&.permit!&.to_h || {},
        idempotency_key: key,
        state: Message::QUEUED,
        next_attempt_at: Time.current
      )

      if message.save
        render json: message.summary, status: :created
      else
        render json: { errors: message.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # GET /core/messages
    #
    # What this service sent, so a failure is somebody's to look at rather than
    # only a line in a log.
    def index
      messages = Message.where(core_sender: sender).recent
      messages = messages.where(domain: params[:domain]) if params[:domain].present?
      messages = messages.where(state: params[:state]) if params[:state].present?

      render json: { messages: messages.limit(100).map(&:summary) }
    end

    private

    # The sender name is the authenticated service, never a parameter. A caller
    # that could name itself could send mail as another one.
    def sender
      "core-#{calling_service}"
    end
  end
end

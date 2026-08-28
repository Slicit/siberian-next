# frozen_string_literal: true

require "net/http"
require "json"

# Where a message actually goes.
#
# Resolved per attempt rather than per message, deliberately: installing a
# transport module drains a queue that is already backed up, without anybody
# re-queuing anything.
module Transport
  # What every transport returns. `permanent` is the difference between "try
  # again later" and "this will never work": a bad address does not deserve six
  # more attempts to discover the same thing.
  Result = Struct.new(:outcome, :detail, :permanent, keyword_init: true) do
    def delivered? = outcome == "delivered"
    def permanent? = permanent == true
  end

  def self.resolve(orchestrator: ENV.fetch("SIBERIAN_ORCHESTRATOR_URL", "http://orchestrator:3000"),
                   token: Siberian::ServiceIdentity.token_for(:orchestrator))
    implementation = lookup(orchestrator, token)

    if implementation && implementation["url"] && !implementation["built_in"]
      Remote.new(name: implementation["provider"], url: implementation["url"])
    else
      BuiltIn.new
    end
  end

  def self.lookup(orchestrator, token)
    uri = URI.join(orchestrator, "/internal/interfaces/mail.transport.v1")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 5) do |http|
      http.request(request)
    end
    return nil unless response.code.to_i == 200

    JSON.parse(response.body)["implementation"]
  rescue StandardError => e
    # A queue that stops because the Orchestrator is briefly unreachable is
    # worse than one that falls back to the transport the core ships with.
    Rails.logger.warn("could not resolve a transport: #{e.message}")
    nil
  end

  # A module implementing mail.transport.v1. The core does not learn which
  # module answered; it was handed a URL.
  class Remote
    attr_reader :name

    def initialize(name:, url:)
      @name = name
      @url = url
    end

    def deliver(message)
      uri = URI.parse(@url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["X-Siberian-Domain"] = message.domain
      request.body = JSON.generate(message.to_payload)

      response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 30) do |http|
        http.request(request)
      end

      code = response.code.to_i
      return Transport::Result.new(outcome: "delivered", detail: "HTTP #{code}") if code.between?(200, 299)

      # A 4xx from a transport is it telling us the message is wrong, which
      # another attempt will not fix. A 5xx is it having a bad day.
      Transport::Result.new(
        outcome: "rejected", permanent: code.between?(400, 499),
        detail: "HTTP #{code}: #{response.body.to_s[0, 300]}"
      )
    rescue StandardError => e
      Transport::Result.new(outcome: "error", detail: e.message, permanent: false)
    end
  end

  # What the core ships with.
  #
  # In development it records rather than sends, which is the honest behaviour:
  # a development box that quietly emails real people is a worse bug than one
  # that sends nothing. Configure SMTP and it sends.
  class BuiltIn
    attr_reader :name

    def initialize
      @name = ENV["SMTP_ADDRESS"].present? ? "core-smtp" : "core-recorder"
    end

    def deliver(message)
      return record(message) if ENV["SMTP_ADDRESS"].blank?

      send_over_smtp(message)
    end

    private

    def record(message)
      Rails.logger.info(
        "[mail] would send to=#{message.to} subject=#{message.subject.inspect} " \
        "module=#{message.module_registration.module_name} domain=#{message.domain}"
      )
      Transport::Result.new(outcome: "delivered", detail: "recorded, no SMTP configured")
    end

    def send_over_smtp(message)
      require "net/smtp"

      body = build_rfc822(message)

      Net::SMTP.start(
        ENV.fetch("SMTP_ADDRESS"), ENV.fetch("SMTP_PORT", 587).to_i,
        ENV.fetch("SMTP_DOMAIN", message.domain),
        ENV["SMTP_USERNAME"], ENV["SMTP_PASSWORD"],
        ENV.fetch("SMTP_AUTH", "plain").to_sym
      ) do |smtp|
        smtp.send_message(body, sender_for(message), message.to)
      end

      Transport::Result.new(outcome: "delivered", detail: "smtp")
    rescue Net::SMTPFatalError, Net::SMTPSyntaxError => e
      # 5xx from SMTP is permanent by definition.
      Transport::Result.new(outcome: "rejected", detail: e.message, permanent: true)
    rescue StandardError => e
      Transport::Result.new(outcome: "error", detail: e.message, permanent: false)
    end

    def sender_for(message)
      message.from.presence || ENV.fetch("SMTP_FROM", "no-reply@#{message.domain}")
    end

    def build_rfc822(message)
      lines = [
        "From: #{sender_for(message)}",
        "To: #{message.to}",
        "Subject: #{message.subject}",
        "MIME-Version: 1.0"
      ]
      lines << "Cc: #{message.cc}" if message.cc.present?
      lines << "Reply-To: #{message.reply_to}" if message.reply_to.present?
      (message.headers || {}).each { |key, value| lines << "#{key}: #{value}" }

      if message.html_body.present?
        lines << "Content-Type: text/html; charset=UTF-8"
        lines << ""
        lines << message.html_body
      else
        lines << "Content-Type: text/plain; charset=UTF-8"
        lines << ""
        lines << message.text_body.to_s
      end

      lines.join("\r\n")
    end
  end
end

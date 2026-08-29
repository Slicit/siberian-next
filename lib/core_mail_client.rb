# frozen_string_literal: true

require "net/http"
require "json"
require_relative "service_identity"

module Siberian
  # How a core service hands a message to the Mailer.
  #
  # Deliberately thin. Everything that makes sending mail survivable already
  # lives in the Mailer: the queue, the backoff, the dead state, the transport
  # interface. This is the door, and a door with retry logic of its own would be
  # a second opinion about when to give up.
  #
  # `deliver` returns nil when the Mailer could not be reached, and a caller
  # that treats that as fatal is making the wrong trade: a password reset that
  # was accepted and not queued is worth reporting, and one that fails the whole
  # request because the Mailer restarted is worse than one that says "check your
  # inbox" and is chased in the queue.
  class CoreMailClient
    def initialize(endpoint: ENV.fetch("SIBERIAN_MAILER_URL", "http://mailer:3000"),
                   token: Siberian::ServiceIdentity.token_for(:mailer),
                   logger: nil)
      @endpoint = endpoint
      @token = token
      @logger = logger
    end

    # An idempotency key is worth passing for anything a person triggers. Two
    # password reset emails for one click reads as an attack to whoever gets
    # them.
    def deliver(domain:, to:, subject:, text_body:, html_body: nil, from: nil,
                reply_to: nil, idempotency_key: nil)
      post("/core/messages", {
        domain: domain, to: to, subject: subject,
        text_body: text_body, html_body: html_body,
        from: from, reply_to: reply_to,
        idempotency_key: idempotency_key
      }.compact)
    end

    def sent(domain: nil, state: nil)
      query = { domain: domain, state: state }.compact
      path = "/core/messages"
      path += "?#{URI.encode_www_form(query)}" unless query.empty?
      get(path)
    end

    private

    def post(path, body)
      request = Net::HTTP::Post.new(URI.join(@endpoint, path))
      request.body = JSON.generate(body)
      request["Content-Type"] = "application/json"
      send_request(request)
    end

    def get(path)
      send_request(Net::HTTP::Get.new(URI.join(@endpoint, path)))
    end

    def send_request(request)
      uri = request.uri
      request["Authorization"] = "Bearer #{@token}"

      response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 8) do |http|
        http.request(request)
      end

      unless response.code.to_i.between?(200, 299)
        log("the mailer refused: HTTP #{response.code} #{response.body.to_s[0, 200]}")
        return nil
      end

      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue StandardError => e
      log("could not reach the mailer: #{e.message}")
      nil
    end

    def log(message)
      @logger ? @logger.warn(message) : warn(message)
    end
  end
end

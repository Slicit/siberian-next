# frozen_string_literal: true

require "net/http"
require "json"
require_relative "service_identity"

module Siberian
  # What the Backoffice asks the Mailer.
  #
  # Read and retry, nothing else. Sending is a module's business or a core
  # service's, and an operator who could send mail from this page would be a
  # sending path with no queue behind it.
  #
  # This exists because the queue was invisible. An operator wanting to know why
  # mail was not arriving had to reach for curl and an admin token, which is the
  # moment they would least want to, and the mail queue is where a password
  # reset now lives.
  class MailerClient
    def initialize(endpoint: ENV.fetch("SIBERIAN_MAILER_URL", "http://mailer:3000"),
                   token: Siberian::ServiceIdentity.token_for(:mailer),
                   logger: nil)
      @endpoint = endpoint
      @token = token
      @logger = logger
    end

    def queue(state: nil, unacknowledged: nil, limit: 100)
      query = { state: state, unacknowledged: unacknowledged, limit: limit }.compact
      get("/admin/queue?#{URI.encode_www_form(query)}")
    end

    # Putting a dead message back is the one thing an operator does here that
    # changes anything. It needs the sending module's token, which the
    # Backoffice does not hold, so it goes through the admin door.
    def retry_message(id) = post("/admin/queue/#{id}/retry", {})

    private

    def get(path) = send_request(Net::HTTP::Get.new(URI.join(@endpoint, path)))

    def post(path, body)
      request = Net::HTTP::Post.new(URI.join(@endpoint, path))
      request.body = JSON.generate(body)
      request["Content-Type"] = "application/json"
      send_request(request)
    end

    def send_request(request)
      uri = request.uri
      request["Authorization"] = "Bearer #{@token}"

      response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 8) do |http|
        http.request(request)
      end

      return nil unless response.code.to_i.between?(200, 299)

      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue StandardError => e
      # nil is "could not answer". A page that will not render because the
      # Mailer is restarting is worse than one that says so.
      @logger ? @logger.warn("mailer call failed: #{e.message}") : warn(e.message)
      nil
    end
  end
end

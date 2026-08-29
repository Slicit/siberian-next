# frozen_string_literal: true

require "net/http"
require "json"
require_relative "service_identity"

module Siberian
  # What the Backoffice asks the Database service.
  #
  # Read only, and only the audit trail. Provisioning and grants happen at
  # install time from the installer; an operator browsing this page is asking
  # what has happened, not making it happen.
  #
  # The trail existed and had no page. Reaching a module's use of somebody
  # else's tables meant curl and an admin token, which makes "who read what"
  # a question nobody asks.
  class DatabaseClient
    # `SIBERIAN_DATABASE_URL_SERVICE`, not `SIBERIAN_DATABASE_URL`: the second
    # name is Rails's own and setting it would point every service at the
    # wrong Postgres.
    def initialize(endpoint: ENV.fetch("SIBERIAN_DATABASE_URL_SERVICE", "http://database:3000"),
                   token: Siberian::ServiceIdentity.token_for(:database),
                   logger: nil)
      @endpoint = endpoint
      @token = token
      @logger = logger
    end

    def audit(module_name: nil, refusals: nil, limit: 200)
      query = { module_name: module_name, refusals: refusals, limit: limit }.compact
      get("/admin/audit?#{URI.encode_www_form(query)}")
    end

    private

    def get(path)
      uri = URI.join(@endpoint, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"

      response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 8) do |http|
        http.request(request)
      end

      return nil unless response.code.to_i.between?(200, 299)

      JSON.parse(response.body)
    rescue StandardError => e
      @logger ? @logger.warn("database call failed: #{e.message}") : warn(e.message)
      nil
    end
  end
end

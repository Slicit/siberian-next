# frozen_string_literal: true

require "net/http"
require "json"

# Asks Auth who is signed in.
#
# The Backoffice does not implement a login and does not hold a password. It
# forwards the browser's cookie to the one service that can read it, which is
# the same thing a module does.
class AuthClient
  Identity = Struct.new(:id, :email, :name, :operator, keyword_init: true) do
    def operator? = operator == true
  end

  def initialize(endpoint: ENV.fetch("SIBERIAN_AUTH_URL", "http://auth:3000"))
    @endpoint = endpoint
  end

  # @return [Identity, nil]
  def identify(session_token)
    return nil if session_token.blank?

    uri = URI.join(@endpoint, "/internal/session")
    request = Net::HTTP::Get.new(uri)
    request["X-Siberian-Session"] = session_token

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 5) do |http|
      http.request(request)
    end

    return nil unless response.code.to_i == 200

    payload = JSON.parse(response.body)
    return nil unless payload["authenticated"]

    user = payload.fetch("user")
    Identity.new(id: user["id"], email: user["email"], name: user["name"], operator: user["operator"])
  rescue StandardError => e
    Rails.logger.warn("auth unreachable: #{e.message}")
    nil
  end

  def reachable?
    uri = URI.join(@endpoint, "/up")
    Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 3) do |http|
      http.request(Net::HTTP::Get.new(uri)).code.to_i == 200
    end
  rescue StandardError
    false
  end
end

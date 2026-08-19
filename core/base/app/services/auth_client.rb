# frozen_string_literal: true

require "net/http"
require "json"

# Asks Auth who is signed in. The Base App holds no password and implements no
# login: it forwards the browser cookie to the one service that can read it.
class AuthClient
  Identity = Struct.new(:id, :email, :name, :operator, keyword_init: true) do
    def operator? = operator == true
  end

  def initialize(endpoint: ENV.fetch("SIBERIAN_AUTH_URL", "http://auth:3000"))
    @endpoint = endpoint
  end

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
end

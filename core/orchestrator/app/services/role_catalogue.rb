# frozen_string_literal: true

require "net/http"
require "json"

# Asks Auth to deliver catalogue permissions to roles seeded before they
# existed.
#
# A thin client on purpose. The decision about which permissions may be added to
# a role an operator has edited belongs to the service that owns roles, not to
# the caller that noticed it was time to ask.
class RoleCatalogue
  class Error < StandardError; end

  def initialize(auth_url: ENV.fetch("SIBERIAN_AUTH_URL", "http://auth:3000"),
                 admin_token: Siberian::ServiceIdentity.token_for(:auth))
    @auth_url = auth_url
    @admin_token = admin_token
  end

  # Returns { role_name => [permission, ...] } for what was added, which is
  # empty on the overwhelmingly common run where nothing has changed.
  def reconcile!
    uri = URI.join(@auth_url, "/internal/roles/reconcile")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@admin_token}"
    request["Content-Type"] = "application/json"
    request.body = "{}"

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 15) do |http|
      http.request(request)
    end

    unless response.code.to_i.between?(200, 299)
      raise Error, "#{uri} returned #{response.code}: #{response.body.to_s[0, 200]}"
    end

    body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
    Hash(body["added"])
  rescue Errno::ECONNREFUSED, Net::OpenTimeout => e
    raise Error, "#{@auth_url} unreachable: #{e.message}"
  end
end

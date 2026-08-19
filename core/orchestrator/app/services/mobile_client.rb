# frozen_string_literal: true

require "net/http"
require "json"

# Reads and writes the phone app configuration, for the Backoffice.
#
# The Mobile service owns the app, the capability list, and the queue; this only
# asks. Keeping the decisions on one side means the page and the build can never
# disagree about what the app was built with.
class MobileClient
  def initialize(endpoint: ENV.fetch("SIBERIAN_MOBILE_URL", "http://mobile:3000"),
                 token: ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only"))
    @endpoint = endpoint
    @token = token
  end

  def apps = request(Net::HTTP::Get, "/admin/apps")
  def app(domain) = request(Net::HTTP::Get, "/admin/apps/#{CGI.escape(domain)}")

  def save_app(domain, attributes)
    request(Net::HTTP::Put, "/admin/apps/#{CGI.escape(domain)}", attributes)
  end

  def remove_app(domain) = request(Net::HTTP::Delete, "/admin/apps/#{CGI.escape(domain)}")

  def set_capability(domain, capability, attributes)
    request(Net::HTTP::Patch,
            "/admin/apps/#{CGI.escape(domain)}/capabilities/#{CGI.escape(capability)}",
            attributes)
  end

  def builds(domain: nil)
    path = domain ? "/admin/builds?domain=#{CGI.escape(domain)}" : "/admin/builds"
    request(Net::HTTP::Get, path)
  end

  def build(id) = request(Net::HTTP::Get, "/admin/builds/#{id}")
  def queue_build(attributes) = request(Net::HTTP::Post, "/admin/builds", attributes)
  def cancel_build(id) = request(Net::HTTP::Post, "/admin/builds/#{id}/cancel", {})

  def reachable? = !apps.nil?

  private

  def request(verb, path, body = nil)
    uri = URI.join(@endpoint, path)
    message = verb.new(uri)
    message["Authorization"] = "Bearer #{@token}"

    if body
      message["Content-Type"] = "application/json"
      message.body = JSON.generate(body)
    end

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 15) do |http|
      http.request(message)
    end

    parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)

    # A refusal that carries a reason is more useful than a nil. The build
    # endpoint answers 422 with which capability is missing which setting, and
    # an operator can act on that.
    return parsed.merge("ok" => false) unless response.code.to_i.between?(200, 299)

    parsed.is_a?(Hash) ? parsed.merge("ok" => true) : parsed
  rescue StandardError => e
    Rails.logger.warn("mobile call failed: #{e.message}")
    nil
  end
end

# frozen_string_literal: true

require "net/http"
require "json"
require "cgi"

module Siberian
  # Reads and writes the phone app configuration.
  #
  # Shared, because two interfaces ask the same questions of the same service:
  # the Backoffice, where an operator sees every domain, and the product shell,
  # where somebody sees only their own. The Mobile service owns the app, the
  # capability list, and the queue; this only asks.
  class MobileClient
    def initialize(endpoint: ENV.fetch("SIBERIAN_MOBILE_URL", "http://mobile:3000"),
                   token: ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only"),
                   logger: nil)
      @endpoint = endpoint
      @token = token
      @logger = logger
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

    # A proposal, never a change. The service answers with what it would do and
    # why; applying any of it is a separate call somebody has to make.
    def suggest(domain, description)
      request(Net::HTTP::Post, "/admin/apps/#{CGI.escape(domain)}/suggest",
              { description: description }, read_timeout: 180)
    end

    # The still image, and the Android animation. Sent as bytes rather than as
    # a JSON field: base64 in a body that then gets logged is how an image ends
    # up in three places nobody meant to put it.
    def upload_splash(domain, bytes, background: nil)
      query = background.present? ? "?background=#{CGI.escape(background)}" : ""
      request(Net::HTTP::Post, "/admin/apps/#{CGI.escape(domain)}/splash#{query}",
              bytes, read_timeout: 60, content_type: "image/png")
    end

    def upload_splash_animation(domain, bytes, duration_ms: nil)
      query = duration_ms.present? ? "?duration_ms=#{duration_ms.to_i}" : ""
      request(Net::HTTP::Post, "/admin/apps/#{CGI.escape(domain)}/splash/animation#{query}",
              bytes, read_timeout: 60, content_type: "application/xml")
    end

    def remove_splash(domain, kind: "image")
      request(Net::HTTP::Delete, "/admin/apps/#{CGI.escape(domain)}/splash?kind=#{CGI.escape(kind)}")
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

    # The assistant takes as long as it takes, which is why the timeout is a
    # parameter: three seconds is right for reading a page and wrong for asking
    # a model to think.
    def request(verb, path, body = nil, read_timeout: 15, content_type: nil)
      uri = URI.join(@endpoint, path)
      message = verb.new(uri)
      message["Authorization"] = "Bearer #{@token}"

      if body && content_type
        message["Content-Type"] = content_type
        message.body = body
      elsif body
        message["Content-Type"] = "application/json"
        message.body = JSON.generate(body)
      end

      response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: read_timeout) do |http|
        http.request(message)
      end

      parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)

      # A refusal that carries a reason is more useful than a nil. The build
      # endpoint answers 422 with which capability is missing which setting, and
      # somebody can act on that.
      return parsed.merge("ok" => false) unless response.code.to_i.between?(200, 299)

      parsed.is_a?(Hash) ? parsed.merge("ok" => true) : parsed
    rescue StandardError => e
      @logger&.warn("mobile call failed: #{e.message}")
      nil
    end
  end
end

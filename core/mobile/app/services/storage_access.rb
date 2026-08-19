# frozen_string_literal: true

require "net/http"
require "json"

# Puts a finished app where every other file in this system lives.
#
# The Mobile service registers with Storage exactly as a module does, so an app
# artifact is governed by the quotas an operator already set: a domain that has
# filled its allowance cannot store a new build of its app, and the refusal
# names the limit that stopped it rather than failing somewhere in Gradle.
#
# The builder never holds this credential. It runs third-party module code, so
# the artifact comes back through this service rather than going out from there.
class StorageAccess
  class Refused < StandardError; end

  MODULE_NAME = "mobile"

  def initialize(endpoint: ENV.fetch("SIBERIAN_STORAGE_URL", "http://storage:3000"),
                 admin_token: ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only"))
    @endpoint = endpoint
    @admin_token = admin_token
  end

  # Stores one artifact and answers where it went. Provisioning is lazy: the
  # first build for a domain is also the moment that domain first needs a
  # bucket, and asking earlier would create buckets for domains with no app.
  def store(domain:, path:, body:, content_type: "application/octet-stream")
    ensure_bucket!(domain)

    response = put("/v1/files/#{path}", body, {
                     "Authorization" => "Bearer #{module_token}",
                     "X-Siberian-Domain" => domain,
                     "Content-Type" => content_type
                   })

    unless response.code.to_i.between?(200, 299)
      raise Refused, refusal_of(response)
    end

    { path: "files/#{path}", bytes: body.bytesize }
  end

  private

  def module_token
    credential = ServiceCredential.find_by(service: "storage")
    return credential.token if credential

    body = post_json("/admin/modules", {
                       module_name: MODULE_NAME,
                       module_uuid: "core-mobile",
                       spaces: ["files"],
                       quota_mb: Integer(ENV.fetch("SIBERIAN_MOBILE_QUOTA_MB", "2048"))
                     })

    token = body && body["token"]
    raise Refused, "Storage would not register the mobile service" if token.to_s.empty?

    ServiceCredential.create!(service: "storage", token: token)
    token
  end

  def ensure_bucket!(domain)
    post_json("/admin/modules/#{MODULE_NAME}/buckets", { domain: domain })
  end

  def refusal_of(response)
    parsed = JSON.parse(response.body.to_s)
    reason = parsed["reason"] || parsed["error"]
    # Storage answers 507 with which limit was hit. Passing that through is the
    # difference between "the build failed" and "this domain is full".
    reason.to_s.empty? ? "Storage refused the artifact (#{response.code})" : reason
  rescue JSON::ParserError
    "Storage refused the artifact (#{response.code})"
  end

  def post_json(path, payload)
    response = request(Net::HTTP::Post, path, JSON.generate(payload),
                       { "Authorization" => "Bearer #{@admin_token}", "Content-Type" => "application/json" })
    return nil unless response.code.to_i.between?(200, 299)

    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  end

  def put(path, body, headers)
    request(Net::HTTP::Put, path, body, headers)
  end

  def request(verb, path, body, headers)
    uri = URI.join(@endpoint, path)
    message = verb.new(uri)
    headers.each { |key, value| message[key] = value }
    message.body = body

    Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 120) do |http|
      http.request(message)
    end
  end
end

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
                 admin_token: Siberian::ServiceIdentity.token_for(:storage))
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

    { path: "files/#{path}", bytes: byte_count(body) }
  end

  # Takes one out again.
  #
  # Used by artifact retention rather than by a build: a superseded APK is sixty
  # megabytes that nothing will install, and nothing used to remove one.
  def remove(domain:, path:)
    response = request(Net::HTTP::Delete, "/v1/#{path}", nil, {
                         "Authorization" => "Bearer #{module_token}",
                         "X-Siberian-Domain" => domain
                       })

    # 404 is success for a delete: the object is not there, which is the state
    # being asked for.
    code = response.code.to_i
    return true if code.between?(200, 299) || code == 404

    raise Refused, "could not remove #{path}: #{code}"
  end

  # Reads one back. The builder never holds this credential, so an asset it
  # needs comes to it through here, the same way the artifact goes out.
  def fetch(domain:, path:)
    response = request(Net::HTTP::Get, "/v1/#{path}", nil, {
                         "Authorization" => "Bearer #{module_token}",
                         "X-Siberian-Domain" => domain
                       })

    return nil unless response.code.to_i.between?(200, 299)

    [response.body, response["Content-Type"]]
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

  # An IO is streamed rather than read. A finished Android build is tens of
  # megabytes, and `message.body = io.read` would hold all of it here on top of
  # the copy Storage is holding on the other end.
  #
  # Net::HTTP insists on knowing the length up front when given a stream,
  # because without one it would have to buffer to find out, which is the thing
  # being avoided.
  def request(verb, path, body, headers)
    uri = URI.join(@endpoint, path)
    message = verb.new(uri)
    headers.each { |key, value| message[key] = value }

    if body.respond_to?(:read)
      message.body_stream = body
      message["Content-Length"] = size_of(body).to_s
    elsif body
      message.body = body
    end

    Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 120) do |http|
      http.request(message)
    end
  end

  # What was actually sent, for the build record and the quota figure. An IO has
  # been consumed by the time this is asked, so it reports its length rather
  # than its contents.
  def byte_count(body)
    return body.bytesize unless body.respond_to?(:read)

    size_of(body)
  end

  def size_of(io)
    return io.size if io.respond_to?(:size) && io.size

    # A Rack input with no size is rare but not impossible. Falling back to
    # reading it defeats the streaming, so it is worth being loud about.
    raise Refused, "cannot upload a stream of unknown length"
  end
end

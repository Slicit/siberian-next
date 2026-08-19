# frozen_string_literal: true

require "net/http"
require "json"

# Garage's admin API: create buckets, mint keys, grant a key access to a bucket.
#
# Separate from the S3 client on purpose. Object operations go through the S3
# protocol, which any backend speaks; provisioning is Garage-specific and lives
# here, so swapping the backend later means rewriting this file and not the
# controllers.
class GarageAdmin
  class Error < StandardError; end

  def initialize(endpoint: ENV.fetch("GARAGE_ADMIN_ENDPOINT", "http://garage:3903"),
                 token: ENV.fetch("GARAGE_ADMIN_TOKEN", "storage_service_dev_only"))
    @endpoint = endpoint
    @token = token
  end

  def healthy?
    post("/v2/GetClusterStatus", {})
    true
  rescue StandardError
    false
  end

  # Idempotent: a bucket that already exists is the state the caller wanted.
  def create_bucket(name)
    response = post("/v2/CreateBucket", { "globalAlias" => name })
    response.fetch("id")
  rescue Error => e
    existing = find_bucket(name)
    return existing.fetch("id") if existing

    raise e
  end

  def find_bucket(name)
    post("/v2/ListBuckets", {}).find do |bucket|
      Array(bucket["globalAliases"]).include?(name)
    end
  rescue StandardError
    nil
  end

  def delete_bucket(bucket_id)
    post("/v2/DeleteBucket", { "id" => bucket_id })
    true
  rescue Error
    false
  end

  # One key per bucket rather than one key per module: a key that can reach only
  # one bucket cannot reach another domain's data even if it leaks.
  def create_key(name)
    response = post("/v2/CreateKey", { "name" => name })
    {
      access_key_id: response.fetch("accessKeyId"),
      secret_access_key: response.fetch("secretAccessKey")
    }
  end

  def delete_key(access_key_id)
    post("/v2/DeleteKey", { "id" => access_key_id })
    true
  rescue Error
    false
  end

  def allow_key(bucket_id:, access_key_id:, read: true, write: true, owner: false)
    post("/v2/AllowBucketKey", {
      "bucketId" => bucket_id,
      "accessKeyId" => access_key_id,
      "permissions" => { "read" => read, "write" => write, "owner" => owner }
    })
    true
  end

  private

  def post(path, body)
    uri = URI.join(@endpoint, path)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 15) do |http|
      http.request(request)
    end

    unless response.code.to_i.between?(200, 299)
      raise Error, "garage admin #{path} returned #{response.code}: #{response.body}"
    end

    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout => e
    raise Error, "garage admin unreachable at #{@endpoint}: #{e.message}"
  end
end

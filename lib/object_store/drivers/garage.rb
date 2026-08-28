# frozen_string_literal: true

require "net/http"
require "json"
require_relative "../driver"

module Siberian
  module ObjectStore
    module Drivers
      # Garage, self hosted, and the first backend this project ran on.
      #
      # Its admin API is its own: creating a bucket, minting a key, and granting
      # that key access to that bucket are three calls that exist nowhere in the
      # S3 protocol. That is the entire reason this interface exists, because
      # reading and writing the objects afterwards is ordinary S3 and needs
      # nothing from here.
      #
      # What Garage does better than AWS for this project's shape: a key can be
      # minted per bucket in one call, with no policy document and no account
      # wide identity object. A leaked key reaches one bucket.
      class Garage < Driver
        DEFAULT_ENDPOINT = "http://garage:3900"
        DEFAULT_ADMIN_ENDPOINT = "http://garage:3903"

        def initialize(endpoint: nil, admin_endpoint: nil, admin_token: nil,
                       public_endpoint: nil, region: nil)
          @endpoint = endpoint || env("SIBERIAN_OBJECT_STORE_ENDPOINT") ||
                      ENV.fetch("GARAGE_ENDPOINT", DEFAULT_ENDPOINT)
          @admin_endpoint = admin_endpoint || env("SIBERIAN_OBJECT_STORE_ADMIN_ENDPOINT") ||
                            ENV.fetch("GARAGE_ADMIN_ENDPOINT", DEFAULT_ADMIN_ENDPOINT)
          @admin_token = admin_token || env("SIBERIAN_OBJECT_STORE_ADMIN_TOKEN") ||
                         ENV.fetch("GARAGE_ADMIN_TOKEN", "storage_service_dev_only")
          # Explicitly nil rather than defaulted: without a public address the
          # Storage service serves bytes itself, which works and simply costs
          # more, and inventing an address here would produce signed URLs
          # pointing at a host nobody can reach.
          @public_endpoint = public_endpoint || env("SIBERIAN_OBJECT_STORE_PUBLIC_ENDPOINT") ||
                             env("GARAGE_PUBLIC_ENDPOINT")
          @region = region || env("SIBERIAN_OBJECT_STORE_REGION") ||
                    ENV.fetch("GARAGE_REGION", "garage")
        end

        def name = "garage"

        def endpoint = @endpoint
        def public_endpoint = @public_endpoint
        def region = @region
        def force_path_style? = true

        def healthy?
          post("/v2/GetClusterStatus", {})
          true
        rescue StandardError
          false
        end

        def provision(bucket_name)
          handle = create_bucket(bucket_name)
          key = create_key("#{bucket_name}-key")

          allow_key(handle: handle, access_key_id: key[:access_key_id])

          Provisioned.new(
            access_key_id: key[:access_key_id],
            secret_access_key: key[:secret_access_key],
            handle: handle,
            # One key, one bucket. This is the property the rest of the system
            # is allowed to rely on when this driver is in use.
            scoped: true
          )
        end

        def deprovision(name:, handle: nil, access_key_id: nil)
          delete_key(access_key_id) if present?(access_key_id)

          handle ||= find_bucket(name)&.fetch("id", nil)
          delete_bucket(handle) if present?(handle)
          true
        end

        def exists?(bucket_name) = !find_bucket(bucket_name).nil?

        private

        # Idempotent: a bucket that already exists is the state the caller
        # wanted, and Garage answers a duplicate alias with an error rather than
        # a shrug.
        def create_bucket(bucket_name)
          response = post("/v2/CreateBucket", { "globalAlias" => bucket_name })
          response.fetch("id")
        rescue Error => e
          existing = find_bucket(bucket_name)
          return existing.fetch("id") if existing

          raise e
        end

        def find_bucket(bucket_name)
          post("/v2/ListBuckets", {}).find do |bucket|
            Array(bucket["globalAliases"]).include?(bucket_name)
          end
        rescue StandardError
          nil
        end

        def delete_bucket(handle)
          post("/v2/DeleteBucket", { "id" => handle })
          true
        rescue Error
          false
        end

        def create_key(key_name)
          response = post("/v2/CreateKey", { "name" => key_name })
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

        def allow_key(handle:, access_key_id:, read: true, write: true, owner: true)
          post("/v2/AllowBucketKey", {
            "bucketId" => handle,
            "accessKeyId" => access_key_id,
            "permissions" => { "read" => read, "write" => write, "owner" => owner }
          })
          true
        end

        def post(path, body)
          uri = URI.join(@admin_endpoint, path)
          request = Net::HTTP::Post.new(uri)
          request["Authorization"] = "Bearer #{@admin_token}"
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)

          response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 15) do |http|
            http.request(request)
          end

          unless response.code.to_i.between?(200, 299)
            raise Error, "object store admin #{path} returned #{response.code}: #{response.body}"
          end

          response.body.to_s.empty? ? {} : JSON.parse(response.body)
        rescue Errno::ECONNREFUSED, Net::OpenTimeout => e
          raise Error, "object store admin unreachable at #{@admin_endpoint}: #{e.message}"
        end
      end
    end
  end
end

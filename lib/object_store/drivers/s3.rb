# frozen_string_literal: true

require "aws-sdk-s3"
require_relative "../driver"

module Siberian
  module ObjectStore
    module Drivers
      # AWS S3, and anything that speaks its API with an access key: OVH, Scaleway,
      # Backblaze, Wasabi, a MinIO somebody else runs.
      #
      # The interesting difference from the self hosted driver is credentials,
      # and it is worth being exact about rather than papering over.
      #
      # Garage mints a key per bucket in one call, so each bucket's credential
      # reaches that bucket and nothing else. S3 has no such call. The nearest
      # equivalent is an IAM user per bucket with an inline policy, which means
      # this service holding IAM write permission for the account, one identity
      # per (module, domain) pair against a hard account limit, and an access key
      # to rotate for each. That is a large amount of blast radius acquired in
      # order to reduce blast radius.
      #
      # So this driver uses one account credential for every bucket and says so,
      # by reporting `scoped: false`. The isolation between one domain's files
      # and another's then rests on the Storage service, which is where the rest
      # of it already rests: the service is the only holder of any credential,
      # modules never see one, and every request is resolved to a bucket from the
      # module token and the domain header before a key is touched.
      #
      # What changes is the honesty of the claim, not the architecture. An
      # operator who wants the stronger promise runs the self hosted backend, and
      # `Provisioned#scoped?` is how anything above here can tell which it got.
      class S3 < Driver
        def initialize(endpoint: nil, public_endpoint: nil, region: nil,
                       access_key_id: nil, secret_access_key: nil,
                       force_path_style: nil, client: nil)
          @endpoint = endpoint || env("SIBERIAN_OBJECT_STORE_ENDPOINT")
          # Defaults to the endpoint. Against real AWS both are absent and the
          # SDK's own regional address is used, which a browser can already
          # reach: the s3 door on the Router exists for a store the internet
          # cannot see, and against AWS it is unnecessary rather than wrong.
          @public_endpoint = public_endpoint || env("SIBERIAN_OBJECT_STORE_PUBLIC_ENDPOINT") || @endpoint
          @region = region || env("SIBERIAN_OBJECT_STORE_REGION") || "us-east-1"
          @access_key_id = access_key_id || env("SIBERIAN_OBJECT_STORE_ACCESS_KEY_ID")
          @secret_access_key = secret_access_key || env("SIBERIAN_OBJECT_STORE_SECRET_ACCESS_KEY")

          # AWS deprecated path style addressing; every self hosted gateway
          # still requires it. Inferred from whether an endpoint was named,
          # because naming one is what says "not AWS", and overridable for the
          # cases where that inference is wrong.
          @force_path_style =
            if force_path_style.nil?
              flag = env("SIBERIAN_OBJECT_STORE_PATH_STYLE")
              flag.nil? ? !@endpoint.nil? : flag == "true"
            else
              force_path_style
            end

          @client = client
        end

        def name = "s3"

        def endpoint = @endpoint
        def public_endpoint = @public_endpoint
        def region = @region
        def force_path_style? = @force_path_style

        def healthy?
          client.list_buckets
          true
        rescue StandardError
          false
        end

        # Creates the bucket if it is not there, and hands back the account
        # credential. Idempotent, including the two ways S3 says "it is already
        # yours".
        def provision(bucket_name)
          create_bucket(bucket_name)

          unless present?(@access_key_id) && present?(@secret_access_key)
            raise Error, "no credentials configured: set SIBERIAN_OBJECT_STORE_ACCESS_KEY_ID " \
                         "and SIBERIAN_OBJECT_STORE_SECRET_ACCESS_KEY"
          end

          Provisioned.new(
            access_key_id: @access_key_id,
            secret_access_key: @secret_access_key,
            # There is no separate identifier: on S3 a bucket is its name.
            handle: bucket_name,
            # Said plainly. See the note at the top of this class.
            scoped: false
          )
        end

        # Deletes the bucket, and nothing else.
        #
        # No key is deleted, because none was minted: removing the account
        # credential here would take away every other bucket's access at the
        # same time. That asymmetry with the self hosted driver is the reason
        # deprovision takes an access_key_id it is free to ignore.
        def deprovision(name:, handle: nil, access_key_id: nil)
          client.delete_bucket(bucket: handle || name)
          true
        rescue Aws::S3::Errors::NoSuchBucket
          true
        rescue Aws::S3::Errors::BucketNotEmpty
          # S3 refuses to delete a bucket with objects in it, and emptying one
          # from here would destroy a domain's files as a side effect of
          # removing a module. Data outlives the module unless an operator says
          # otherwise, which is the same rule the provisioner already follows.
          raise Refused, "#{name} still has objects in it; empty it before removing the bucket"
        rescue Aws::S3::Errors::ServiceError => e
          raise Error, "could not remove #{name}: #{e.message}"
        end

        def exists?(bucket_name)
          client.head_bucket(bucket: bucket_name)
          true
        rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchBucket
          false
        rescue Aws::S3::Errors::Forbidden
          # Somebody else owns a bucket by that name. It exists, and it is not
          # ours, which is a different problem and not this method's to report.
          true
        end

        private

        def create_bucket(bucket_name)
          # us-east-1 is the one region that must not be named in the location
          # constraint, and naming it is an InvalidLocationConstraint error that
          # reads like a typo.
          options = { bucket: bucket_name }
          options[:create_bucket_configuration] = { location_constraint: @region } unless @region == "us-east-1"

          client.create_bucket(**options)
          true
        rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
          true
        rescue Aws::S3::Errors::BucketAlreadyExists
          # The name is taken by another account. S3 bucket names are globally
          # unique, so this is a real conflict rather than idempotence, and it
          # will not resolve itself.
          raise Refused, "the bucket name #{bucket_name} is already taken in S3, which is a global namespace"
        rescue Aws::S3::Errors::ServiceError => e
          raise Error, "could not create #{bucket_name}: #{e.message}"
        end

        def client
          @client ||= Aws::S3::Client.new(**client_options)
        end

        def client_options
          options = { region: @region }
          options[:endpoint] = @endpoint if present?(@endpoint)
          options[:force_path_style] = @force_path_style
          if present?(@access_key_id) && present?(@secret_access_key)
            options[:access_key_id] = @access_key_id
            options[:secret_access_key] = @secret_access_key
          end
          # Credentials left out entirely when none are configured, so the SDK
          # falls back to its own chain: an instance role, a task role, or a
          # profile. That is how this should be run on AWS, and hardcoding empty
          # strings would break it.
          options
        end
      end
    end
  end
end

# frozen_string_literal: true

require "aws-sdk-s3"

# The objects in one bucket: putting, getting, deleting, and listing.
#
# Shared by every backend rather than written per backend, because this half is
# the S3 protocol and every object store worth supporting speaks it. What
# differs is how a bucket and its credentials come into existence, and that is
# behind `Siberian::ObjectStore.driver`.
#
# So this class knows an object store is involved and does not know which one.
# It asks the driver where to send the request and signs with the credentials
# the driver minted for this bucket.
class StoredObjects
  class NotFound < StandardError; end
  class Error < StandardError; end

  Stored = Struct.new(:key, :size, :content_type, :etag, :last_modified, keyword_init: true)

  def initialize(bucket)
    @bucket = bucket
  end

  def put(space, path, body, content_type: nil)
    key = @bucket.key_for(space, path)
    io = body.respond_to?(:read) ? body : StringIO.new(body.to_s)

    result = client.put_object(
      bucket: @bucket.name,
      key: key,
      body: io,
      content_type: content_type.presence || "application/octet-stream"
    )

    Stored.new(key: key, size: io.size, content_type: content_type, etag: result.etag)
  rescue Aws::S3::Errors::ServiceError => e
    raise Error, e.message
  end

  def get(space, path)
    key = @bucket.key_for(space, path)
    object = client.get_object(bucket: @bucket.name, key: key)
    [object.body.read, object.content_type, object.content_length]
  rescue Aws::S3::Errors::NoSuchKey
    raise NotFound, path
  rescue Aws::S3::Errors::ServiceError => e
    raise Error, e.message
  end

  # The same object, without ever holding all of it.
  #
  # `get` asks the SDK for a response whose body is a StringIO, which means a
  # 67 MB artifact is 67 MB of Ruby heap in this process for as long as the
  # download takes, once per concurrent reader. The block form of `get_object`
  # yields chunks as they arrive instead, and an Enumerator turns that into
  # something Rails can hand to Rack as a streaming body.
  #
  # Metadata comes from a separate HEAD because the size and content type have
  # to be on the response before the first chunk is written, and the block form
  # only returns them once it has finished. That is one extra round trip inside
  # the storage network, which is a good trade against buffering the object.
  #
  # Returns [Stored, Enumerator].
  def stream(space, path)
    key = @bucket.key_for(space, path)
    meta = head(space, path)

    body = Enumerator.new do |yielder|
      client.get_object(bucket: @bucket.name, key: key) do |chunk|
        yielder << chunk
      end
    end

    [meta, body]
  rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
    raise NotFound, path
  rescue Aws::S3::Errors::ServiceError => e
    raise Error, e.message
  end

  def head(space, path)
    key = @bucket.key_for(space, path)
    object = client.head_object(bucket: @bucket.name, key: key)
    Stored.new(
      key: key,
      size: object.content_length,
      content_type: object.content_type,
      etag: object.etag,
      last_modified: object.last_modified
    )
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    raise NotFound, path
  end

  def delete(space, path)
    client.delete_object(bucket: @bucket.name, key: @bucket.key_for(space, path))
    true
  rescue Aws::S3::Errors::ServiceError => e
    raise Error, e.message
  end

  def list(space, prefix: nil, limit: 100, cursor: nil)
    response = client.list_objects_v2(
      bucket: @bucket.name,
      prefix: @bucket.key_for(space, prefix.to_s),
      max_keys: limit,
      continuation_token: cursor.presence
    )

    {
      objects: response.contents.map do |object|
        {
          path: object.key.delete_prefix("#{space}/"),
          size: object.size,
          etag: object.etag,
          last_modified: object.last_modified
        }
      end,
      cursor: response.next_continuation_token,
      truncated: response.is_truncated
    }
  rescue Aws::S3::Errors::ServiceError => e
    raise Error, e.message
  end

  # Used by the sweeper and by quota accounting. Garage has no lifecycle rules,
  # so expiry is something this service does rather than something it configures.
  def each_object(space, older_than: nil)
    cursor = nil
    loop do
      page = list(space, limit: 1000, cursor: cursor)
      page[:objects].each do |object|
        next if older_than && object[:last_modified] && object[:last_modified] > older_than

        yield object
      end
      cursor = page[:cursor]
      break unless page[:truncated]
    end
  end

  def total_bytes
    total = 0
    ModuleRegistration::SPACES.each do |space|
      each_object(space) { |object| total += object[:size].to_i }
    end
    total
  end

  # A URL the caller can fetch from the object store directly, valid for a
  # while and for one object.
  #
  # This is how a service stops carrying bytes it has no opinion about. The
  # signature is made with this bucket's own key, so the URL grants exactly one
  # object to whoever holds it and nothing else in the bucket, and it stops
  # working when it expires.
  #
  # Signed against the public address rather than the internal one, because the
  # host is part of what gets signed: a URL signed for an address only the
  # inside of the stack can reach, then rewritten to a reachable one, is a URL
  # with a broken signature.
  def presigned_get_url(space, path, expires_in:)
    Aws::S3::Presigner.new(client: public_client).presigned_url(
      :get_object,
      bucket: @bucket.name,
      key: @bucket.key_for(space, path),
      expires_in: expires_in
    )
  end

  # An address the caller can write one object to, directly.
  #
  # The other half of the read path. Bytes coming in still travel through this
  # service: a finished Android build is tens of megabytes that the builder
  # hands to the Mobile service, which hands them here, which hands them to the
  # object store. Streaming stopped that costing memory; it did not stop it
  # costing three transfers of the same file.
  #
  # `content_type` is signed into the URL, so the object arrives with the type
  # the caller declared rather than whatever the store guesses. That means the
  # PUT must send exactly this Content-Type or the signature will not match,
  # which is worth knowing before it is discovered.
  def presigned_put_url(space, path, expires_in:, content_type: nil)
    Aws::S3::Presigner.new(client: public_client).presigned_url(
      :put_object,
      bucket: @bucket.name,
      key: @bucket.key_for(space, path),
      expires_in: expires_in,
      **(content_type ? { content_type: content_type } : {})
    )
  end

  # Whether there is a public address to sign against at all. Without one the
  # caller serves the bytes itself rather than handing out a URL to a host that
  # does not resolve.
  def self.public_endpoint = driver.public_endpoint

  # One driver for the process. Which backend is in use is a deployment
  # decision read once at boot, not a question to ask per request.
  def self.driver
    @driver ||= Siberian::ObjectStore.driver
  end

  # Tests, and anything that changes the environment underneath a running
  # process.
  def self.reset_driver! = @driver = nil

  private

  def driver = self.class.driver

  def client
    @client ||= build_client(driver.endpoint)
  end

  # The same credentials, addressed the way the outside world reaches the store.
  # Used only for signing: nothing is ever fetched through this one from here.
  def public_client
    @public_client ||= build_client(driver.public_endpoint || driver.endpoint)
  end

  def build_client(endpoint)
    Aws::S3::Client.new(
      access_key_id: @bucket.access_key_id,
      secret_access_key: @bucket.secret_access_key,
      endpoint: endpoint,
      region: driver.region,
      force_path_style: driver.force_path_style?
    )
  end
end

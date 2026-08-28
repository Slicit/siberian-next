# frozen_string_literal: true

require "aws-sdk-s3"

# The S3 half of storage: putting, getting, deleting, and listing objects.
#
# This class and GarageAdmin are the only code in the repository that knows an
# object store is involved. Everything above them deals in spaces and paths.
class ObjectStore
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
  # host is part of what gets signed: a URL signed for `garage:3900` and then
  # rewritten to a reachable host is a URL with a broken signature.
  def presigned_get_url(space, path, expires_in:)
    Aws::S3::Presigner.new(client: public_client).presigned_url(
      :get_object,
      bucket: @bucket.name,
      key: @bucket.key_for(space, path),
      expires_in: expires_in
    )
  end

  # Whether the public door is configured at all. Without it there is nothing
  # to sign against, and the caller should serve the bytes itself rather than
  # hand out a URL to a host that does not resolve.
  def self.public_endpoint
    ENV["GARAGE_PUBLIC_ENDPOINT"].presence
  end

  private

  def client
    @client ||= build_client(ENV.fetch("GARAGE_ENDPOINT", "http://garage:3900"))
  end

  # Same credentials, addressed the way the outside world reaches Garage. Used
  # only for signing: nothing is ever fetched through this one from here.
  def public_client
    @public_client ||= build_client(
      self.class.public_endpoint || ENV.fetch("GARAGE_ENDPOINT", "http://garage:3900")
    )
  end

  def build_client(endpoint)
    Aws::S3::Client.new(
      access_key_id: @bucket.access_key_id,
      secret_access_key: @bucket.secret_access_key,
      endpoint: endpoint,
      region: ENV.fetch("GARAGE_REGION", "garage"),
      force_path_style: true
    )
  end
end

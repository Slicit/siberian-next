# frozen_string_literal: true

require_relative "object_store/driver"

module Siberian
  # Object store abstraction. See lib/object_store/README.md.
  #
  # The same shape as Siberian::Engine, for the same reason: the backend is a
  # deployment choice and nothing above the driver should be able to tell which
  # one it got.
  module ObjectStore
    BACKENDS = {
      garage: "Siberian::ObjectStore::Drivers::Garage",
      s3: "Siberian::ObjectStore::Drivers::S3"
    }.freeze

    # @param backend [Symbol] key from BACKENDS, defaults to ENV or :garage
    # @return [Driver]
    def self.driver(backend = nil, **options)
      backend ||= (ENV["SIBERIAN_OBJECT_STORE"] || "garage").to_sym
      const_name = BACKENDS.fetch(backend) do
        raise ArgumentError, "unknown object store backend: #{backend.inspect}"
      end
      require_relative "object_store/drivers/#{backend}"
      Object.const_get(const_name).new(**options)
    end
  end
end

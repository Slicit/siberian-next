# frozen_string_literal: true

require_relative "siberian_engine/container_spec"
require_relative "siberian_engine/unix_http"
require_relative "siberian_engine/driver"

module Siberian
  # Container engine abstraction. See lib/siberian_engine/README.md.
  module Engine
    BACKENDS = {
      docker: "Siberian::Engine::Drivers::Docker"
      # kubernetes: "Siberian::Engine::Drivers::Kubernetes"
    }.freeze

    # @param backend [Symbol] key from BACKENDS, defaults to ENV or :docker
    # @return [Driver]
    def self.driver(backend = nil, **options)
      backend ||= (ENV["SIBERIAN_ENGINE"] || "docker").to_sym
      const_name = BACKENDS.fetch(backend) do
        raise ArgumentError, "unknown engine backend: #{backend.inspect}"
      end
      require_relative "siberian_engine/drivers/#{backend}"
      Object.const_get(const_name).new(**options)
    end
  end
end

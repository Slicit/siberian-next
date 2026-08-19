# frozen_string_literal: true

require_relative "../driver"

module Siberian
  module Engine
    module Drivers
      # Docker backend, the first one.
      #
      # STATUS: interface mapping only. No method here has been executed against
      # a daemon yet, because the development environment has no container
      # engine installed (see LOGBOOK/features/feat-monorepo-skeleton.md).
      # Every method raises until it is implemented and exercised. Do not
      # assume any of this works.
      #
      # Mapping decisions, so the Kubernetes backend has something to mirror:
      #
      #   Engine concept      Docker                 Kubernetes (later)
      #   ------------------  ---------------------  --------------------------
      #   ContainerSpec       container + config     Pod template
      #   network             user-defined bridge    Namespace + NetworkPolicy
      #   aliases             network alias          Service name
      #   module boundary     one network per uuid   one Namespace per uuid
      #   datastore isolation no published port      NetworkPolicy ingress deny
      #
      # Talks to the daemon over the API rather than shelling out to the CLI:
      # the CLI's output is a presentation format and parsing it is how drivers
      # rot. Socket path is configurable so a rootless or remote daemon works
      # without code changes.
      class Docker < Driver
        DEFAULT_SOCKET = "/var/run/docker.sock"
        LABEL_PREFIX   = "siberian"

        attr_reader :socket

        def initialize(socket: ENV.fetch("DOCKER_SOCKET", DEFAULT_SOCKET))
          @socket = socket
        end

        def create(spec, network:)
          not_implemented(__method__)
        end

        def start(id)                     = not_implemented(__method__)
        def stop(id, timeout_seconds: 10) = not_implemented(__method__)
        def remove(id, force: false)      = not_implemented(__method__)
        def status(id)                    = not_implemented(__method__)
        def healthy?(id)                  = not_implemented(__method__)
        def logs(id, since: nil, follow: false) = not_implemented(__method__)

        def create_network(name) = not_implemented(__method__)
        def remove_network(name) = not_implemented(__method__)
        def attach(id, network:, aliases: []) = not_implemented(__method__)
        def detach(id, network:) = not_implemented(__method__)

        def list(labels: {}) = not_implemented(__method__)
        def version          = not_implemented(__method__)
      end
    end
  end
end

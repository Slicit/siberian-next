# frozen_string_literal: true

module Siberian
  module Engine
    # Engine-neutral description of one container.
    #
    # Built by the Orchestrator from a module manifest, consumed by a Driver.
    # Deliberately says nothing a Kubernetes backend could not honour: no
    # Docker run flags, no compose keys, no daemon concepts.
    ContainerSpec = Struct.new(
      :name,          # String, "<uuid>-<module_name>-<service>"
      :image,         # String
      :role,          # Symbol, :http | :worker | :datastore
      :aliases,       # Array<String>, internal DNS names this answers to
      :env,           # Hash<String, String>
      :mounts,        # Array<Mount>
      :internal_port, # Integer or nil, only meaningful for :http
      :health,        # Health or nil
      :labels,        # Hash<String, String>, module uuid and name live here
      keyword_init: true
    ) do
      def http?      = role == :http
      def datastore? = role == :datastore

      # A datastore is never reachable from outside its module network. The
      # driver is expected to enforce this, not merely to avoid publishing it.
      def externally_routable? = http?
    end

    Mount  = Struct.new(:path, :access, keyword_init: true)          # access: :read | :write
    Health = Struct.new(:path, :interval_seconds, keyword_init: true)
  end
end

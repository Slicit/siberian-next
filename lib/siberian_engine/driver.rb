# frozen_string_literal: true

module Siberian
  module Engine
    # The interface every container backend implements.
    #
    # Callers depend on this class, never on a concrete backend. Methods raise
    # NotImplementedError rather than returning nil so that a half-implemented
    # backend fails loudly at the seam instead of quietly one layer up.
    class Driver
      Error         = Class.new(StandardError)
      NotFound      = Class.new(Error)
      AlreadyExists = Class.new(Error)
      Unhealthy     = Class.new(Error)

      # Lifecycle. All of these take or return engine-neutral values only.

      # @param spec [ContainerSpec]
      # @param network [String] the module network to attach to
      # @return [String] engine-assigned identifier
      def create(spec, network:) = not_implemented(__method__)

      def start(id)  = not_implemented(__method__)
      def stop(id, timeout_seconds: 10) = not_implemented(__method__)
      def remove(id, force: false)      = not_implemented(__method__)

      # @return [Symbol] :running | :stopped | :restarting | :dead | :absent
      def status(id) = not_implemented(__method__)

      # @return [Boolean] whether the container passes its declared health check
      def healthy?(id) = not_implemented(__method__)

      # @param since [Time, nil]
      # @return [Enumerator<String>]
      def logs(id, since: nil, follow: false) = not_implemented(__method__)

      # Networking. One network per module, which is what keeps a module's
      # datastores unreachable from anywhere else.

      def create_network(name)  = not_implemented(__method__)
      def remove_network(name)  = not_implemented(__method__)
      def attach(id, network:, aliases: []) = not_implemented(__method__)
      def detach(id, network:)  = not_implemented(__method__)

      # Discovery.

      # @param labels [Hash] filter, typically { "siberian.module_uuid" => uuid }
      # @return [Array<Hash>] engine-neutral summaries: id, name, status, labels
      def list(labels: {}) = not_implemented(__method__)

      # Images. A module declares images it does not ship, so fetching them is
      # an engine capability the Orchestrator needs. The interface grew for it
      # rather than letting the caller reach past the driver.

      def pull(image) = not_implemented(__method__)
      def image_present?(image) = not_implemented(__method__)

      # Backend identity, for the Backoffice to display and for tests to skip on.
      def name    = self.class.name.split("::").last.downcase
      def version = not_implemented(__method__)

      private

      def not_implemented(method)
        raise NotImplementedError, "#{self.class}##{method} is not implemented"
      end
    end
  end
end

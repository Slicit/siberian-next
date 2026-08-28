# frozen_string_literal: true

module Siberian
  module ObjectStore
    # The interface every object store backend implements.
    #
    # Only the control plane is here. Reading and writing objects is the S3
    # protocol, which every backend worth supporting already speaks, so that
    # code is shared and parameterised by `endpoint` and `region` rather than
    # reimplemented per backend. What actually differs between Garage and AWS is
    # everything around the objects: how a bucket comes into existence, how a
    # credential is minted, and how tightly that credential can be scoped.
    #
    # Callers depend on this class, never on a concrete backend, the same rule
    # the container engine follows. `bin/check-storage-leak` enforces it.
    #
    # Methods raise NotImplementedError rather than returning nil so a half
    # written backend fails at the seam instead of quietly one layer up.
    class Driver
      Error    = Class.new(StandardError)
      NotFound = Class.new(Error)
      Refused  = Class.new(Error)

      # What a bucket needs in order to be used.
      #
      # `handle` is whatever the backend calls this bucket internally, kept so
      # deprovisioning does not have to look it up again. Garage assigns an
      # opaque id; AWS has nothing but the name, and stores the name.
      #
      # `scoped` says whether the credential reaches only this bucket. Garage
      # mints a key per bucket, so it does. A backend that cannot do that says
      # so rather than implying an isolation it does not provide.
      Provisioned = Struct.new(:access_key_id, :secret_access_key, :handle, :scoped,
                               keyword_init: true) do
        def scoped? = scoped == true
      end

      # Which backend this is, for logs and for the Backoffice. Never branched
      # on: code that asks which backend it is talking to is code that belongs
      # behind this interface.
      def name = not_implemented(__method__)

      # Whether the backend is reachable. Used by the health card, so it answers
      # false rather than raising.
      def healthy? = not_implemented(__method__)

      # Ensure a bucket exists and return credentials for it.
      #
      # Idempotent: an existing bucket is the state the caller wanted. Returns
      # fresh credentials each time it is called, because the caller stores them
      # and a caller that already had working ones does not call this.
      #
      # @param name [String]
      # @return [Provisioned]
      def provision(name) = not_implemented(__method__)

      # Remove a bucket and any credential minted for it. Idempotent, and never
      # raises for something that is already gone.
      #
      # @param name [String]
      # @param handle [String, nil] as returned by provision
      # @param access_key_id [String, nil]
      def deprovision(name:, handle: nil, access_key_id: nil) = not_implemented(__method__)

      # Whether a bucket exists. Used by reconciliation rather than by the hot
      # path.
      def exists?(name) = not_implemented(__method__)

      # Where the S3 protocol is spoken, from inside the stack.
      def endpoint = not_implemented(__method__)

      # Where a browser reaches it, which is what presigned URLs are signed
      # against because the host is part of the signature. Nil when there is no
      # public address, in which case the Storage service serves the bytes
      # itself instead of handing out a URL.
      def public_endpoint = not_implemented(__method__)

      def region = not_implemented(__method__)

      # Whether path style addressing is required. Garage and most self hosted
      # gateways need it; AWS deprecated it and prefers the bucket in the host.
      def force_path_style? = not_implemented(__method__)

      private

      def not_implemented(method)
        raise NotImplementedError, "#{self.class}##{method} is not implemented"
      end

      # ActiveSupport is not available here. lib/ is loaded by six Rails
      # services and also by `bin/test-lib` in a bare Ruby container, so
      # anything in here that needs Rails to load is a file that cannot be
      # tested.
      def env(key)
        value = ENV[key]
        value && !value.strip.empty? ? value : nil
      end

      def present?(value) = !value.nil? && !value.to_s.strip.empty?
    end
  end
end

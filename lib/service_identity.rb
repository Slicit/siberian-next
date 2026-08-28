# frozen_string_literal: true

require "digest"
# OpenSSL rather than ActiveSupport::SecurityUtils, which says the same thing:
# lib/ is shared by six Rails services and also loaded by `bin/test-lib` in a
# bare Ruby container, so anything in here that needs Rails to load is a file
# that cannot be tested.
require "openssl"

module Siberian
  # Which core service is calling, and what it may therefore do.
  #
  # Before this, every service authenticated every other with one shared bearer
  # (`SIBERIAN_ADMIN_TOKEN`). That token is admin everywhere, so compromising any
  # one service was compromising all of them: the Mailer could mint database
  # credentials, the Storage service could delete a domain's buckets. Nothing in
  # the system needed those powers, and nothing checked whether the caller had a
  # reason to be asking.
  #
  # The secret is per pair of services rather than per service, which is the
  # part worth being deliberate about. A single token per caller would still
  # mean that whoever holds the Orchestrator's token can act as the Orchestrator
  # against everything, and every callee has to know that token to check it. So
  # a compromised Storage service would read its own environment and own the
  # rest. With one secret per (caller, callee) pair, the most Storage can learn
  # is how to talk to Storage.
  #
  # Two directions, because a service is usually both:
  #
  #   SIBERIAN_CALLERS   who may call me, and the token each of them presents
  #   SIBERIAN_CALLEES   who I call, and the token I present to each
  #
  # Both are `name=token,name=token`. A service that is only ever called sets
  # the first; one that only calls sets the second; the Orchestrator sets both.
  module ServiceIdentity
    # Accepted while a deployment still has only the old shared token in its
    # environment. Recognisable on sight, and reported by `legacy?` so callers
    # can say so out loud rather than silently behaving as they did before.
    LEGACY = :legacy

    class << self
      def own_name = ENV["SIBERIAN_SERVICE_NAME"].presence

      # Who may call this service. Empty when nothing has been configured, which
      # is what puts the whole thing in legacy mode.
      def callers = @callers ||= parse(ENV["SIBERIAN_CALLERS"])

      # What this service presents when it calls somebody else.
      def callees = @callees ||= parse(ENV["SIBERIAN_CALLEES"])

      # True when this service has no idea who is allowed to call it, and is
      # therefore falling back to the shared admin token.
      def legacy? = callers.empty?

      # The token to present when calling `service`.
      #
      # Falls back to the shared token so that a service which has not been
      # given a pair token yet keeps working against a callee that has not been
      # given one either. Both halves have to be configured before anything
      # changes, which is what makes this safe to roll out one service at a
      # time.
      def token_for(service)
        callees[service.to_s] || legacy_token
      end

      # Which caller does this bearer token belong to?
      #
      # Returns the caller's name, LEGACY when the deployment is still on the
      # shared token, or nil when the token is not recognised at all.
      def identify(bearer)
        token = bearer.to_s
        return nil if token.empty?

        # Compared against every configured caller rather than looked up, so
        # that the comparison is constant time. A hash lookup on a secret leaks
        # its prefix through timing, which is a small leak and an unnecessary
        # one.
        match = callers.find { |_name, expected| secure_equal?(token, expected) }
        return match.first if match

        return LEGACY if legacy? && secure_equal?(token, legacy_token)

        nil
      end

      # The shared bearer this replaces. Still read, because a deployment that
      # has not been reconfigured must keep working.
      def legacy_token = ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only")

      # Tests and boot-time reconfiguration.
      def reset!
        @callers = nil
        @callees = nil
      end

      private

      def parse(value)
        value.to_s.split(",").each_with_object({}) do |pair, out|
          name, token = pair.split("=", 2)
          next if name.nil? || token.nil?

          name = name.strip
          token = token.strip
          next if name.empty? || token.empty?

          out[name] = token
        end.freeze
      end

      def secure_equal?(given, expected)
        return false if expected.nil? || expected.empty?

        # Hashed to a fixed length first, because the fixed length comparison
        # raises on differing lengths and raising is itself a length oracle.
        OpenSSL.fixed_length_secure_compare(
          ::Digest::SHA256.digest(given.to_s), ::Digest::SHA256.digest(expected.to_s)
        )
      end
    end
  end
end

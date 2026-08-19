# frozen_string_literal: true

# Tests for lib/. The Rails services keep their own suites; this one covers the
# shared code they all depend on, which otherwise would only ever be exercised
# indirectly.
require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("..", __dir__))

require "lib/siberian_engine"

# Backends load lazily in production, through Engine.driver. Tests name the
# class directly, so they load it directly.
require "lib/siberian_engine/drivers/docker"

module Siberian
  module TestSupport
    # Stands in for UnixHTTP so driver tests assert on the requests the driver
    # makes, without a daemon anywhere in sight.
    class FakeHTTP
      attr_reader :calls

      def initialize(responses = {})
        @responses = responses
        @calls = []
      end

      def get(path, query: nil)
        record(:get, path, query, nil)
      end

      def post(path, body: nil, query: nil)
        record(:post, path, query, body)
      end

      def delete(path, query: nil)
        record(:delete, path, query, nil)
      end

      def stream(path, query: nil)
        @calls << { method: :stream, path: path, query: query }
        Array(@responses["stream:#{path}"]).each { |chunk| yield chunk }
        nil
      end

      # Registers a canned response, or an exception to raise.
      def on(method, path, value)
        @responses["#{method}:#{path}"] = value
        self
      end

      private

      def record(method, path, query, body)
        @calls << { method: method, path: path, query: query, body: body }
        value = @responses["#{method}:#{path}"]
        raise value if value.is_a?(StandardError)

        value || Engine::UnixHTTP::Response.new(status: 200, headers: {}, body: "{}")
      end
    end

    def self.response(payload, status: 200)
      Engine::UnixHTTP::Response.new(status: status, headers: {}, body: JSON.generate(payload))
    end
  end
end

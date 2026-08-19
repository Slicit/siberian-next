# frozen_string_literal: true

require "socket"
require "json"
require "uri"

module Siberian
  module Engine
    # Minimal HTTP/1.1 client over a Unix domain socket.
    #
    # Net::HTTP cannot address a Unix socket without reaching into its private
    # state, and the Docker API needs only a narrow slice of HTTP: JSON in, JSON
    # out, plus streamed bodies for logs. A focused client is smaller than the
    # workaround and far easier to reason about when something goes wrong at
    # three in the morning.
    #
    # Lives inside siberian_engine because it exists to talk to a container
    # engine. Nothing above the driver should ever need it.
    class UnixHTTP
      CRLF = "\r\n"

      Response = Struct.new(:status, :headers, :body, keyword_init: true) do
        def success? = status >= 200 && status < 300
        def json = body.nil? || body.empty? ? nil : JSON.parse(body)
      end

      class Error < StandardError
        attr_reader :status, :body

        def initialize(status, body)
          @status = status
          @body = body
          message = begin
            JSON.parse(body).fetch("message", body)
          rescue StandardError
            body
          end
          super("HTTP #{status}: #{message}")
        end
      end

      def initialize(socket_path, timeout: 60)
        @socket_path = socket_path
        @timeout = timeout
      end

      def get(path, query: nil)
        request("GET", path, query: query)
      end

      def post(path, body: nil, query: nil)
        request("POST", path, body: body, query: query)
      end

      def delete(path, query: nil)
        request("DELETE", path, query: query)
      end

      # Yields body chunks as they arrive instead of buffering. Used for logs,
      # where the whole point is not waiting for the end, and for image pulls,
      # which stream progress from a POST.
      def stream(path, query: nil, method: "GET", body: nil)
        payload = body.nil? ? nil : JSON.generate(body)

        with_socket do |sock|
          write_request(sock, method, path, query, payload)
          status, headers = read_head(sock)
          raise Error.new(status, read_body(sock, headers).to_s) unless status >= 200 && status < 300

          if headers["transfer-encoding"].to_s.include?("chunked")
            each_chunk(sock) { |chunk| yield chunk }
          else
            while (chunk = sock.readpartial(16_384))
              yield chunk
            end
          end
        end
      rescue EOFError
        nil
      end

      private

      def request(method, path, body: nil, query: nil)
        payload = body.nil? ? nil : JSON.generate(body)

        with_socket do |sock|
          write_request(sock, method, path, query, payload)
          status, headers = read_head(sock)
          content = read_body(sock, headers)
          response = Response.new(status: status, headers: headers, body: content)
          raise Error.new(status, content.to_s) unless response.success?

          response
        end
      end

      def with_socket
        sock = UNIXSocket.new(@socket_path)
        sock.sync = true
        begin
          yield sock
        ensure
          sock.close unless sock.closed?
        end
      rescue Errno::ENOENT
        raise Error.new(0, "no socket at #{@socket_path}; is the engine running and the socket mounted?")
      rescue Errno::EACCES
        raise Error.new(0, "permission denied on #{@socket_path}; is this user in the engine's group?")
      end

      def write_request(sock, method, path, query, payload)
        full = path
        unless query.nil? || query.empty?
          full = "#{path}?#{URI.encode_www_form(query)}"
        end

        lines = ["#{method} #{full} HTTP/1.1"]
        lines << "Host: localhost"
        lines << "Accept: application/json"
        lines << "Connection: close"
        if payload
          lines << "Content-Type: application/json"
          lines << "Content-Length: #{payload.bytesize}"
        end

        sock.write(lines.join(CRLF) + CRLF + CRLF)
        sock.write(payload) if payload
      end

      def read_head(sock)
        status_line = sock.gets(CRLF).to_s
        status = status_line.split(" ")[1].to_i

        headers = {}
        while (line = sock.gets(CRLF))
          break if line == CRLF || line.strip.empty?

          name, _, value = line.partition(":")
          headers[name.strip.downcase] = value.strip
        end

        [status, headers]
      end

      def read_body(sock, headers)
        if headers["transfer-encoding"].to_s.include?("chunked")
          buffer = +""
          each_chunk(sock) { |chunk| buffer << chunk }
          buffer
        elsif (length = headers["content-length"])
          length.to_i.zero? ? "" : sock.read(length.to_i)
        else
          # Connection: close with no length. Read until the peer hangs up.
          sock.read
        end
      rescue EOFError
        ""
      end

      def each_chunk(sock)
        loop do
          size_line = sock.gets(CRLF)
          break if size_line.nil?

          size = size_line.strip.split(";").first.to_i(16)
          break if size.zero?

          chunk = sock.read(size)
          sock.read(2) # trailing CRLF
          yield chunk if chunk
        end
      end
    end
  end
end

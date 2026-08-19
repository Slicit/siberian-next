# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Exercises the client against a real Unix socket rather than a stubbed one.
# The parts most likely to break (chunked decoding, header parsing, close
# without a length) only exist because of what a real socket does.
class UnixHTTPTest < Minitest::Test
  include Siberian

  CRLF = "\r\n"

  def setup
    @dir = Dir.mktmpdir("siberian-test")
    @path = File.join(@dir, "test.sock")
    @requests = []
  end

  def teardown
    @server&.close
    @thread&.kill
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  # Serves one canned response, capturing the request it received.
  def serve(raw_response)
    @server = UNIXServer.new(@path)
    @thread = Thread.new do
      loop do
        client = @server.accept
        request = +""
        while (line = client.gets(CRLF))
          request << line
          break if line == CRLF
        end
        if (match = request[/Content-Length: ([0-9]+)/i, 1])
          request << client.read(match.to_i).to_s
        end
        @requests << request
        client.write(raw_response)
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    Engine::UnixHTTP.new(@path)
  end

  def json_response(payload, status: 200)
    body = JSON.generate(payload)
    "HTTP/1.1 #{status} OK#{CRLF}Content-Type: application/json#{CRLF}" \
      "Content-Length: #{body.bytesize}#{CRLF}#{CRLF}#{body}"
  end

  def test_get_parses_a_content_length_body
    http = serve(json_response({ "Version" => "29.7.2" }))

    response = http.get("/version")

    assert_equal 200, response.status
    assert_equal "29.7.2", response.json.fetch("Version")
  end

  def test_query_parameters_reach_the_server
    http = serve(json_response([]))

    http.get("/containers/json", query: { "all" => true, "limit" => 5 })

    assert_includes @requests.first, "GET /containers/json?all=true&limit=5 HTTP/1.1"
  end

  def test_post_sends_a_json_body_with_a_content_length
    http = serve(json_response({ "Id" => "abc" }))

    http.post("/containers/create", body: { "Image" => "nginx" })

    request = @requests.first
    assert_includes request, "Content-Type: application/json"
    assert_includes request, '{"Image":"nginx"}'
  end

  def test_a_chunked_body_is_reassembled
    body = JSON.generate({ "ok" => true })
    first = body[0, 4]
    rest = body[4..]
    raw = "HTTP/1.1 200 OK#{CRLF}Transfer-Encoding: chunked#{CRLF}#{CRLF}" \
          "#{first.bytesize.to_s(16)}#{CRLF}#{first}#{CRLF}" \
          "#{rest.bytesize.to_s(16)}#{CRLF}#{rest}#{CRLF}" \
          "0#{CRLF}#{CRLF}"
    http = serve(raw)

    assert_equal({ "ok" => true }, http.get("/anything").json)
  end

  def test_a_body_with_no_length_is_read_until_close
    raw = "HTTP/1.1 200 OK#{CRLF}Content-Type: application/json#{CRLF}#{CRLF}{\"ok\":true}"
    http = serve(raw)

    assert_equal({ "ok" => true }, http.get("/anything").json)
  end

  def test_an_error_status_raises_with_the_engine_message
    http = serve(json_response({ "message" => "No such container: nope" }, status: 404))

    error = assert_raises(Engine::UnixHTTP::Error) { http.get("/containers/nope/json") }

    assert_equal 404, error.status
    assert_includes error.message, "No such container: nope"
  end

  def test_stream_yields_each_chunk
    raw = "HTTP/1.1 200 OK#{CRLF}Transfer-Encoding: chunked#{CRLF}#{CRLF}" \
          "5#{CRLF}hello#{CRLF}5#{CRLF}world#{CRLF}0#{CRLF}#{CRLF}"
    http = serve(raw)

    chunks = []
    http.stream("/containers/x/logs") { |chunk| chunks << chunk }

    assert_equal %w[hello world], chunks
  end

  def test_a_missing_socket_says_so_plainly
    http = Engine::UnixHTTP.new(File.join(@dir, "absent.sock"))

    error = assert_raises(Engine::UnixHTTP::Error) { http.get("/version") }

    assert_includes error.message, "no socket at"
  end
end

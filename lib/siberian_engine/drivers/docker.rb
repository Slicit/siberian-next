# frozen_string_literal: true

require_relative "../driver"
require_relative "../unix_http"

module Siberian
  module Engine
    module Drivers
      # Docker backend, the first one.
      #
      # Talks to the daemon over its HTTP API rather than shelling out to the
      # CLI: the CLI's output is a presentation format, and parsing it is how
      # drivers rot. The socket path is configurable so a rootless or remote
      # daemon works without code changes.
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
      class Docker < Driver
        DEFAULT_SOCKET = "/var/run/docker.sock"
        LABEL_PREFIX = "siberian"

        attr_reader :socket

        def initialize(socket: ENV.fetch("DOCKER_SOCKET", DEFAULT_SOCKET), http: nil)
          @socket = socket
          @http = http || UnixHTTP.new(socket)
        end

        # Lifecycle ----------------------------------------------------------

        def create(spec, network:)
          ensure_image(spec.image)

          response = @http.post("/containers/create", body: container_config(spec, network), query: { "name" => spec.name })
          response.json.fetch("Id")
        rescue UnixHTTP::Error => e
          raise AlreadyExists, e.message if e.status == 409

          raise Error, e.message
        end

        def start(id)
          @http.post("/containers/#{id}/start")
          true
        rescue UnixHTTP::Error => e
          # Already running is the state the caller asked for.
          return true if e.status == 304

          raise translate(e, id)
        end

        def stop(id, timeout_seconds: 10)
          @http.post("/containers/#{id}/stop", query: { "t" => timeout_seconds })
          true
        rescue UnixHTTP::Error => e
          return true if e.status == 304

          raise translate(e, id)
        end

        def remove(id, force: false)
          @http.delete("/containers/#{id}", query: { "force" => force, "v" => true })
          true
        rescue UnixHTTP::Error => e
          return true if e.status == 404

          raise translate(e, id)
        end

        def status(id)
          state = inspect_container(id).fetch("State", {})
          case state["Status"]
          when "running" then :running
          when "exited", "created" then :stopped
          when "restarting" then :restarting
          when "dead", "paused" then :dead
          else :absent
          end
        rescue NotFound
          :absent
        end

        def healthy?(id)
          state = inspect_container(id).fetch("State", {})
          return false unless state["Status"] == "running"

          health = state["Health"]
          # No declared healthcheck means running is the best answer available.
          return true if health.nil?

          health["Status"] == "healthy"
        rescue NotFound
          false
        end

        def logs(id, since: nil, follow: false)
          query = { "stdout" => true, "stderr" => true, "timestamps" => true, "follow" => follow }
          query["since"] = since.to_i if since

          return enum_for(:logs, id, since: since, follow: follow) unless block_given?

          @http.stream("/containers/#{id}/logs", query: query) do |chunk|
            demultiplex(chunk) { |line| yield line }
          end
        end

        # Networking ---------------------------------------------------------

        def create_network(name)
          response = @http.post("/networks/create", body: {
            "Name" => name,
            "Driver" => "bridge",
            "CheckDuplicate" => true,
            "Labels" => { "#{LABEL_PREFIX}.managed" => "true" }
          })
          response.json.fetch("Id")
        rescue UnixHTTP::Error => e
          raise AlreadyExists, e.message if e.status == 409

          raise Error, e.message
        end

        def remove_network(name)
          @http.delete("/networks/#{name}")
          true
        rescue UnixHTTP::Error => e
          return true if e.status == 404

          raise Error, e.message
        end

        def attach(id, network:, aliases: [])
          @http.post("/networks/#{network}/connect", body: {
            "Container" => id,
            "EndpointConfig" => { "Aliases" => Array(aliases) }
          })
          true
        rescue UnixHTTP::Error => e
          raise translate(e, id)
        end

        def detach(id, network:)
          @http.post("/networks/#{network}/disconnect", body: { "Container" => id, "Force" => true })
          true
        rescue UnixHTTP::Error => e
          return true if e.status == 404

          raise translate(e, id)
        end

        # Discovery ----------------------------------------------------------

        def list(labels: {})
          query = { "all" => true }
          unless labels.empty?
            filters = { "label" => labels.map { |k, v| "#{k}=#{v}" } }
            query["filters"] = JSON.generate(filters)
          end

          @http.get("/containers/json", query: query).json.map do |raw|
            {
              id: raw["Id"],
              name: Array(raw["Names"]).first.to_s.delete_prefix("/"),
              image: raw["Image"],
              status: raw["State"],
              labels: raw["Labels"] || {}
            }
          end
        end

        # Execution ----------------------------------------------------------

        def exec_in(id, command, detach: false)
          created = @http.post("/containers/#{id}/exec", body: {
            "Cmd" => Array(command),
            "AttachStdout" => !detach,
            "AttachStderr" => !detach,
            "Tty" => false
          })
          exec_id = created.json.fetch("Id")

          output = +""
          @http.stream("/exec/#{exec_id}/start", method: "POST",
                                                 body: { "Detach" => detach, "Tty" => false }) do |chunk|
            demultiplex(chunk) { |line| output << line } unless detach
          end
          output
        rescue UnixHTTP::Error => e
          raise translate(e, id)
        end

        # Images -------------------------------------------------------------

        # Pulling is an engine capability the Orchestrator genuinely needs, so
        # the interface grew rather than the caller reaching past it.
        def pull(image)
          name, tag = split_image(image)
          # The engine streams progress from a POST here, not a GET. Asking for
          # it with a GET returns a bare 404 that says nothing about why.
          @http.stream("/images/create", method: "POST",
                                         query: { "fromImage" => name, "tag" => tag }) { |_chunk| nil }
          true
        rescue UnixHTTP::Error => e
          raise Error, "could not pull #{image}: #{e.message}"
        end

        def image_present?(image)
          @http.get("/images/#{URI.encode_www_form_component(image)}/json")
          true
        rescue UnixHTTP::Error
          false
        end

        def version
          @http.get("/version").json.fetch("Version")
        end

        private

        def ensure_image(image)
          pull(image) unless image_present?(image)
        end

        def inspect_container(id)
          @http.get("/containers/#{id}/json").json
        rescue UnixHTTP::Error => e
          raise translate(e, id)
        end

        def translate(error, id)
          return NotFound.new("no container #{id}") if error.status == 404

          Error.new(error.message)
        end

        def container_config(spec, network)
          config = {
            "Image" => spec.image,
            "Labels" => (spec.labels || {}).merge("#{LABEL_PREFIX}.managed" => "true"),
            "Env" => (spec.env || {}).map { |k, v| "#{k}=#{v}" },
            "HostConfig" => {
              "Binds" => binds_for(spec),
              "RestartPolicy" => { "Name" => "unless-stopped" },
              "NetworkMode" => network
            },
            "NetworkingConfig" => {
              "EndpointsConfig" => { network => { "Aliases" => Array(spec.aliases) } }
            }
          }

          if spec.http? && spec.internal_port
            config["ExposedPorts"] = { "#{spec.internal_port}/tcp" => {} }
          end

          # A datastore is never reachable from outside its module network. No
          # published ports is the enforcement, not merely the default.
          config["HostConfig"]["PublishAllPorts"] = false

          if spec.health && spec.internal_port
            config["Healthcheck"] = healthcheck_for(spec)
          end

          config
        end

        def binds_for(spec)
          Array(spec.mounts).map do |mount|
            mode = mount.access.to_s == "write" ? "rw" : "ro"
            "#{mount.path}:#{mount.path}:#{mode}"
          end
        end

        def healthcheck_for(spec)
          url = "http://127.0.0.1:#{spec.internal_port}#{spec.health.path}"
          interval = (spec.health.interval_seconds || 30)

          # wget covers busybox images, curl covers the rest. An image with
          # neither should declare its own HEALTHCHECK instead.
          probe = "wget -q -O /dev/null #{url} || curl -fsS -o /dev/null #{url}"

          {
            "Test" => ["CMD-SHELL", probe],
            "Interval" => interval * 1_000_000_000,
            "Timeout" => 5 * 1_000_000_000,
            "Retries" => 3,
            "StartPeriod" => 10 * 1_000_000_000
          }
        end

        def split_image(image)
          return image.split("@", 2) if image.include?("@")

          index = image.rindex(":")
          if index && !image[(index + 1)..].to_s.include?("/")
            [image[0...index], image[(index + 1)..]]
          else
            [image, "latest"]
          end
        end

        # Docker multiplexes stdout and stderr into a framed stream when the
        # container has no TTY: 8 byte header, then payload.
        def demultiplex(chunk)
          offset = 0
          while offset + 8 <= chunk.bytesize
            length = chunk.byteslice(offset + 4, 4).unpack1("N")
            payload = chunk.byteslice(offset + 8, length)
            offset += 8 + length.to_i
            next if payload.nil?

            payload.each_line { |line| yield line }
          end
          # Not framed after all (TTY containers). Pass it through.
          yield chunk if offset.zero?
        end
      end
    end
  end
end

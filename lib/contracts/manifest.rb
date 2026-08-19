# frozen_string_literal: true

require "yaml"
require "json"
require "digest"

module Siberian
  module Contracts
    # A parsed module manifest.
    #
    # Turns module.yml into the things the core actually needs: container specs
    # for the engine, capability declarations for the Base App, and permission
    # grants for the Database, Storage, and Mailer services.
    #
    # Validation against the JSON Schema is opt-in, because only the Orchestrator
    # needs it and the schema validator is a gem the other services do not carry.
    class Manifest
      SCHEMA_PATH = File.expand_path("module_manifest.schema.json", __dir__)

      class InvalidManifest < StandardError
        attr_reader :errors

        def initialize(errors)
          @errors = Array(errors)
          super("invalid manifest: #{@errors.join('; ')}")
        end
      end

      attr_reader :data, :source_path

      def self.load(path)
        new(YAML.safe_load_file(path, permitted_classes: [], aliases: false), source_path: path)
      end

      def self.parse(yaml)
        new(YAML.safe_load(yaml, permitted_classes: [], aliases: false))
      end

      def initialize(data, source_path: nil)
        @data = data || {}
        @source_path = source_path
      end

      # Identity -----------------------------------------------------------

      def name = data["name"]
      def version = data["version"]
      def title = data["title"] || name
      def description = data["description"]

      # Containers ---------------------------------------------------------

      def containers = Array(data["containers"])

      def entry_container
        containers.find { |c| c["service"] == routes["entry"] }
      end

      def routes = data["routes"] || {}
      def base_route = routes["base"]
      def origin = routes["origin"] || name

      # The engine-neutral specs the driver consumes. The Orchestrator supplies
      # the uuid; the manifest never carries one, because a manifest describes a
      # module and a uuid identifies an installation of it.
      def container_specs(uuid:)
        containers.map do |container|
          service = container["service"]
          Engine::ContainerSpec.new(
            name: container_name(uuid, service),
            image: container["image"],
            role: container["role"].to_sym,
            aliases: aliases_for(service),
            env: container["env"] || {},
            mounts: mounts_for(container),
            internal_port: container["internal_port"],
            health: health_for(container),
            labels: {
              "siberian.module_uuid" => uuid,
              "siberian.module_name" => name,
              "siberian.service" => service,
              "siberian.role" => container["role"]
            }
          )
        end
      end

      # `<uuid>-<module_name>-<service>`, the naming rule from LOGBOOK.md.
      def container_name(uuid, service)
        "#{uuid}-#{name}-#{service}"
      end

      # One network per installation is what keeps a module's datastores
      # unreachable from anywhere else.
      def network_name(uuid)
        "siberian-mod-#{uuid}"
      end

      # Capabilities -------------------------------------------------------

      def provided_capabilities = Array(data.dig("capabilities", "provides"))
      def consumed_capabilities = Array(data.dig("capabilities", "consumes"))

      # Permissions --------------------------------------------------------

      def permissions = data["permissions"] || {}
      def database_grants = Array(permissions["databases"])
      def storage_grant = permissions["storage"]
      def mail_grant = permissions["mail"]
      def module_grants = Array(permissions["modules"])

      def storage_spaces = Array(storage_grant && storage_grant["spaces"])

      # Everything an operator has to approve at install time, flattened into
      # one list so the Backoffice can show it as one list.
      def requested_permissions
        requests = []

        database_grants.each do |grant|
          target = grant["name"] ? "a new database (#{grant['name']})" : "the existing #{grant['target']} database"
          requests << {
            kind: "database",
            summary: "#{grant['access']} access to #{target}",
            detail: "scope: #{grant['scope'] || 'per_domain'}",
            severity: grant["access"] == "read" ? :low : :high
          }
        end

        if storage_spaces.any?
          requests << {
            kind: "storage",
            summary: "file storage in #{storage_spaces.join(', ')}",
            detail: "quota: #{storage_grant['quota_mb'] || 512} MB",
            severity: storage_spaces.include?("public") ? :medium : :low
          }
        end

        if mail_grant && mail_grant["send"]
          requests << { kind: "mail", summary: "send mail on your behalf", detail: nil, severity: :medium }
        end

        module_grants.each do |grant|
          requests << {
            kind: "module",
            summary: "#{grant['access']} access to the #{grant['name']} module",
            detail: grant["optional"] ? "optional" : "required",
            severity: grant["access"] == "read" ? :low : :high
          }
        end

        requests
      end

      # Validation ---------------------------------------------------------

      # Structural checks that do not need the schema validator. These catch the
      # mistakes that would otherwise surface as a confusing failure much later,
      # halfway through creating containers.
      def structural_errors
        errors = []
        errors << "name is required" if name.to_s.empty?
        errors << "version is required" if version.to_s.empty?
        errors << "at least one container is required" if containers.empty?
        errors << "routes.entry is required" if routes["entry"].to_s.empty?
        errors << "routes.base is required" if base_route.to_s.empty?

        if routes["entry"] && entry_container.nil?
          errors << "routes.entry names #{routes['entry']}, which is not one of the declared containers"
        elsif entry_container && entry_container["role"] != "http"
          errors << "routes.entry must name an http container, but #{routes['entry']} is #{entry_container['role']}"
        elsif entry_container && entry_container["internal_port"].nil?
          errors << "the entry container #{routes['entry']} must declare an internal_port"
        end

        services = containers.map { |c| c["service"] }
        duplicates = services.select { |s| services.count(s) > 1 }.uniq
        errors << "duplicate container services: #{duplicates.join(', ')}" if duplicates.any?

        database_grants.each_with_index do |grant, index|
          if grant["name"] && grant["target"]
            errors << "permissions.databases[#{index}] sets both name and target; it must set exactly one"
          elsif grant["name"].nil? && grant["target"].nil?
            errors << "permissions.databases[#{index}] must set either name or target"
          end
        end

        errors
      end

      def valid?
        structural_errors.empty?
      end

      # Full validation against the contract schema. Needs json_schemer, which
      # only the Orchestrator carries.
      def schema_errors
        require "json_schemer"

        schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
        schema.validate(JSON.parse(JSON.generate(data))).map do |error|
          path = error["data_pointer"].empty? ? "/" : error["data_pointer"]
          "#{path} #{error['type']}"
        end
      rescue LoadError
        raise "schema validation needs the json_schemer gem"
      end

      def validate!
        all = structural_errors
        raise InvalidManifest, all if all.any?

        self
      end

      private

      # The module's short name resolves to its entry container, so the Router
      # and other modules can address it without knowing the uuid. Every
      # container also answers to `<name>-<service>`.
      def aliases_for(service)
        list = ["#{name}-#{service}"]
        list << name if service == routes["entry"]
        list
      end

      def mounts_for(container)
        Array(container["mounts"]).map do |mount|
          Engine::Mount.new(path: mount["path"], access: (mount["access"] || "read").to_sym)
        end
      end

      def health_for(container)
        health = container["health"]
        return nil if health.nil?

        Engine::Health.new(path: health["path"], interval_seconds: health["interval_seconds"] || 30)
      end
    end
  end
end

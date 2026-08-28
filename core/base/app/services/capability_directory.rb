# frozen_string_literal: true

require "net/http"
require "json"

# What the shell shows, and where each thing lives.
#
# The Base App asks the Orchestrator for feature capabilities and gets back a
# title, an area, and a URL. It never learns a container name, a uuid, or a
# network, which is why installing a module does not require changing the shell.
class CapabilityDirectory
  Capability = Struct.new(:id, :title, :area, :icon, :module_name, :module_title, :status, :url, :path,
                          keyword_init: true) do
    def slug = id.tr(".", "-")
    def healthy? = status == "running"
  end

  # Areas the shell knows how to render. A capability declaring an area that is
  # not here is not lost: it appears under More, which is better than vanishing.
  AREAS = {
    "sidebar.primary" => "Main",
    "sidebar.entities" => "Your data",
    "sidebar.tools" => "Tools"
  }.freeze

  def initialize(endpoint: ENV.fetch("SIBERIAN_ORCHESTRATOR_URL", "http://orchestrator:3000"),
                 token: Siberian::ServiceIdentity.token_for(:orchestrator))
    @endpoint = endpoint
    @token = token
  end

  def all(domain:)
    uri = URI.join(@endpoint, "/internal/capabilities")
    uri.query = URI.encode_www_form(domain: domain)

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@token}"

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 3, read_timeout: 8) do |http|
      http.request(request)
    end
    return [] unless response.code.to_i == 200

    JSON.parse(response.body).fetch("capabilities", []).map do |raw|
      Capability.new(
        id: raw["id"], title: raw["title"], area: raw["area"], icon: raw["icon"],
        module_name: raw["module"], module_title: raw["module_title"],
        status: raw["status"], url: raw["url"], path: raw["path"]
      )
    end
  rescue StandardError => e
    # A shell that will not render because the Orchestrator is slow is worse
    # than a shell with an empty sidebar.
    Rails.logger.warn("could not read capabilities: #{e.message}")
    []
  end

  # Grouped the way the sidebar renders, in a stable order, with anything
  # unrecognised collected rather than dropped.
  # `only` is the caller's filter, applied before grouping so an area with
  # nothing visible in it does not render as an empty heading.
  def grouped(domain:, only: nil)
    capabilities = all(domain: domain)
    capabilities = only.call(capabilities) if only
    known = AREAS.keys

    groups = AREAS.filter_map do |area, label|
      found = capabilities.select { |capability| capability.area == area }
      next if found.empty?

      [label, found]
    end

    leftovers = capabilities.reject { |capability| known.include?(capability.area) }
    groups << ["More", leftovers] if leftovers.any?
    groups
  end

  def find(domain:, id:)
    all(domain: domain).find { |capability| capability.id == id || capability.slug == id }
  end
end

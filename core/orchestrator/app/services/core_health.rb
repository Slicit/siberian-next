# frozen_string_literal: true

require "net/http"

# Whether the core itself is up. The Backoffice manages modules, but the first
# question when something is wrong is usually about the core.
class CoreHealth
  Service = Struct.new(:name, :url, :reachable, :detail, keyword_init: true) do
    def reachable? = reachable == true
  end

  SERVICES = {
    "auth" => "http://auth:3000/up",
    "storage" => "http://storage:3000/up",
    "mailer" => "http://mailer:3000/up",
    "base" => "http://base:3000/up"
  }.freeze

  def services
    SERVICES.map do |name, url|
      reachable, detail = probe(url)
      Service.new(name: name, url: url, reachable: reachable, detail: detail)
    end
  end

  def engine
    driver = Siberian::Engine.driver
    Service.new(name: "engine", url: driver.name, reachable: true, detail: driver.version)
  rescue StandardError => e
    Service.new(name: "engine", url: "unknown", reachable: false, detail: e.message)
  end

  private

  def probe(url)
    uri = URI.parse(url)
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 3) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    [response.code.to_i == 200, "HTTP #{response.code}"]
  rescue StandardError => e
    [false, e.class.name.split("::").last]
  end
end

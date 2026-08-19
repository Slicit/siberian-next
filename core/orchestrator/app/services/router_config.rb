# frozen_string_literal: true

# Writes a module's nginx server block and tells the Router to reload.
#
# The Router reads files, so this writes files, into a volume both containers
# share. The reload is the one part that needs to reach into another container,
# which is why the engine interface carries exec_in.
class RouterConfig
  TEMPLATE_CANDIDATES = [
    "lib/router/module.conf.template",
    "../../lib/router/module.conf.template"
  ].freeze

  class ReloadFailed < StandardError; end

  def initialize(driver: Siberian::Engine.driver,
                 config_dir: ENV.fetch("SIBERIAN_ROUTER_CONFIG_DIR", "/var/lib/siberian/router"),
                 router_container: ENV.fetch("SIBERIAN_ROUTER_CONTAINER", "siberian-router-1"))
    @driver = driver
    @config_dir = config_dir
    @router_container = router_container
  end

  # One file per module, named for the module, so removing a module is a single
  # unlink rather than a rewrite of a file everything else also depends on.
  def write(installed_module, domains)
    FileUtils.mkdir_p(@config_dir)
    body = Array(domains).map { |domain| render(installed_module, domain) }.join("\n")
    File.write(path_for(installed_module), body)
    body
  end

  def remove(installed_module)
    FileUtils.rm_f(path_for(installed_module))
  end

  # A module's containers sit on their own network, and the Router sits on the
  # core one. Until the Router joins, the module's short name resolves to
  # nothing and every route answers 502. Joining here rather than putting all
  # modules on one shared network is what keeps module A from reaching module B
  # directly: traffic between modules goes through the Router, by construction.
  def join_network(network_name)
    @driver.attach(@router_container, network: network_name)
    true
  rescue Siberian::Engine::Driver::AlreadyExists
    true
  end

  def leave_network(network_name)
    @driver.detach(@router_container, network: network_name)
    true
  rescue StandardError
    # A network that is already gone needs no leaving.
    true
  end

  # nginx keeps serving the old config until told otherwise, so a write that is
  # never followed by a reload looks exactly like a write that did nothing.
  def reload
    output = @driver.exec_in(@router_container, ["nginx", "-s", "reload"])
    raise ReloadFailed, output if output.to_s.downcase.include?("emerg")

    true
  rescue Siberian::Engine::Driver::NotFound
    raise ReloadFailed, "no router container named #{@router_container}"
  end

  def write_and_reload(installed_module, domains)
    write(installed_module, domains)
    reload
  end

  def path_for(installed_module)
    File.join(@config_dir, "#{installed_module.name}.conf")
  end

  private

  def template
    @template ||= begin
      found = TEMPLATE_CANDIDATES.map { |candidate| Rails.root.join(candidate) }.find { |path| File.exist?(path) }
      raise "router template not found; looked in #{TEMPLATE_CANDIDATES.join(', ')}" unless found

      File.read(found)
    end
  end

  def render(installed_module, domain)
    entry = installed_module.entry_container
    raise "module #{installed_module.name} has no entry container" if entry.nil?

    substitutions = {
      "MODULE_ORIGIN" => installed_module.origin.presence || installed_module.name,
      "MODULE_NAME" => installed_module.name,
      "MODULE_PORT" => entry.internal_port.to_s,
      "SIBERIAN_DOMAIN" => domain.to_s,
      "SIBERIAN_RESOLVER" => ENV.fetch("SIBERIAN_RESOLVER", "127.0.0.11")
    }

    substitutions.reduce(strip_template_header(template)) do |body, (key, value)|
      body.gsub("${#{key}}", value)
    end
  end

  # The template opens with a comment explaining its own placeholders. Rendering
  # that block turns the explanation into nonsense, so it does not travel.
  def strip_template_header(body)
    body.lines.drop_while { |line| line.start_with?("#") || line.strip.empty? }.join
  end
end

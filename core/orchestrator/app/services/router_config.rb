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

  # The names the Router answers to on a module network. "core" is how a module
  # addresses auth, storage, and the mailer: it has no route to them otherwise,
  # which is exactly the isolation we want, so the Router is the door.
  INTERNAL_ALIASES = %w[router core].freeze

  # Sorts before every module file in the include glob, though nginx does not
  # care: a map is http context and resolved per request.
  # Map entries live in a directory of their own, included from inside the map
  # block in 00-core.conf. The map itself has to exist before any module does,
  # or nginx refuses to start on an unknown variable, so the core template owns
  # the block and the Orchestrator owns only what goes in it.
  UPSTREAMS_DIR = "upstreams"

  # The product shell, the Backoffice, and the object store door, one set per
  # served domain. A directory of their own so a domain that is removed is one
  # unlink, the same as a module.
  DOMAINS_DIR = "domains"

  DOMAIN_TEMPLATE_CANDIDATES = [
    "lib/router/domain.conf.template",
    "../../lib/router/domain.conf.template"
  ].freeze

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

  # One file per served domain, rewritten whole from the domains that exist.
  #
  # Rewritten rather than appended to, and files for domains that are gone are
  # removed, because a stale server block is worse than a missing one: nginx
  # keeps answering for a domain nobody serves any more, and the answer looks
  # correct.
  #
  # Returns the domains it wrote, so a caller can say what changed.
  def write_domains(domains)
    directory = File.join(@config_dir, DOMAINS_DIR)
    FileUtils.mkdir_p(directory)

    hostnames = Array(domains).map(&:to_s).reject(&:empty?).uniq
    wanted = hostnames.map { |hostname| "#{hostname}.conf" }

    Dir.glob(File.join(directory, "*.conf")).each do |existing|
      FileUtils.rm_f(existing) unless wanted.include?(File.basename(existing))
    end

    hostnames.each do |hostname|
      File.write(File.join(directory, "#{hostname}.conf"), render_domain(hostname))
    end

    hostnames
  end

  # A module's containers sit on their own network, and the Router sits on the
  # core one. Until the Router joins, the module's short name resolves to
  # nothing and every route answers 502. Joining here rather than putting all
  # modules on one shared network is what keeps module A from reaching module B
  # directly: traffic between modules goes through the Router, by construction.
  def join_network(network_name)
    @driver.attach(@router_container, network: network_name, aliases: INTERNAL_ALIASES)
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

  # One map entry per installed module, its name to its upstream.
  #
  # The app addresses a module as /m/<name>/, and that location lives on the
  # product domain, which no module owns: a per-module server block cannot
  # answer it. A map is the nginx construct for exactly this.
  def refresh_upstreams!(installed_modules)
    directory = File.join(@config_dir, UPSTREAMS_DIR)
    FileUtils.mkdir_p(directory)

    # An earlier version of this wrote one file here instead of a directory of
    # them. The volume outlives an image, so that file sat in conf.d/modules,
    # was included by the *.conf glob as a second map for the same variable,
    # and being frozen at whatever was installed the day it was written it
    # shadowed the real one: a module installed afterwards answered 404 at
    # /m/<name>/ with everything else about it working.
    FileUtils.rm_f(File.join(@config_dir, "00-upstreams.conf"))

    # Rewritten whole rather than appended to, so a module that is gone leaves
    # nothing addressable behind.
    FileUtils.rm_f(Dir.glob(File.join(directory, "*.map")))

    Array(installed_modules).each do |installed|
      entry = installed.entry_container
      next if entry.nil? || entry.internal_port.blank?

      File.write(File.join(directory, "#{installed.name}.map"),
                 "#{installed.name} \"#{installed.name}:#{entry.internal_port}\";\n")
    end
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

  def render_domain(hostname)
    substitutions = {
      "SIBERIAN_DOMAIN" => hostname,
      "SIBERIAN_RESOLVER" => ENV.fetch("SIBERIAN_RESOLVER", "127.0.0.11"),
      # The same defaults compose gives the Router, because this file is
      # rendered here and read there: a placeholder left unsubstituted is a
      # config nginx refuses to load, which takes every domain down and not
      # just this one.
      "SIBERIAN_MAX_UPLOAD" => ENV.fetch("SIBERIAN_MAX_UPLOAD", "1024m"),
      # Asked of the driver rather than hardcoded, so this file names no
      # object store backend and the door follows the deployment's choice.
      "SIBERIAN_OBJECT_STORE_ADDRESS" => object_store_address
    }

    substitutions.reduce(strip_template_header(domain_template)) do |body, (key, value)|
      body.gsub("${#{key}}", value)
    end
  end

  # Where the object store answers S3 from inside the stack, for the door the
  # per-domain template opens at s3.<domain>.
  #
  # An explicit setting wins, so a deployment can put the door somewhere other
  # than the store's own address. Otherwise the driver is asked, which is the
  # one place that knows.
  def object_store_address
    configured = ENV["SIBERIAN_OBJECT_STORE_ADDRESS"].presence
    return configured if configured

    Siberian::ObjectStore.driver.endpoint
  rescue StandardError => e
    # A door that cannot be addressed is one block of one domain. Failing the
    # whole render would take every domain's shell down with it, so this is the
    # rare case where carrying on is right, and it is said out loud.
    Rails.logger.warn("could not determine the object store address: #{e.message}")
    ""
  end

  def domain_template
    @domain_template ||= begin
      path = DOMAIN_TEMPLATE_CANDIDATES.map { |candidate| Rails.root.join(candidate) }.find(&:exist?)
      raise "domain template not found in #{DOMAIN_TEMPLATE_CANDIDATES.join(', ')}" if path.nil?

      File.read(path)
    end
  end

  # The template opens with a comment explaining its own placeholders. Rendering
  # that block turns the explanation into nonsense, so it does not travel.
  def strip_template_header(body)
    body.lines.drop_while { |line| line.start_with?("#") || line.strip.empty? }.join
  end
end

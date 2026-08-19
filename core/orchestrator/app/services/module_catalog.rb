# frozen_string_literal: true

# The modules an operator can install.
#
# A directory for now, a registry later. Reading it is deliberately cheap and
# side-effect free: browsing the catalogue must never touch the engine, and an
# unparseable manifest in it must not stop the page from rendering.
class ModuleCatalog
  Entry = Struct.new(:name, :path, :manifest, :error, keyword_init: true) do
    def valid? = error.nil? && manifest&.valid?

    def problems
      return [error] if error
      return manifest.structural_errors if manifest

      ["unreadable"]
    end

    def installed? = InstalledModule.exists?(name: name)
    def title = manifest&.title || name
    def version = manifest&.version
    def description = manifest&.description
  end

  def initialize(root: ENV.fetch("SIBERIAN_MODULE_CATALOG", "/var/lib/siberian/modules"))
    @root = root
  end

  def available?
    Dir.exist?(@root)
  end

  def entries
    return [] unless available?

    Dir.children(@root).sort.filter_map do |name|
      path = File.join(@root, name, "module.yml")
      next unless File.exist?(path)

      build_entry(name, path)
    end
  end

  def find(name)
    entries.find { |entry| entry.name == name }
  end

  private

  def build_entry(name, path)
    manifest = Siberian::Contracts::Manifest.load(path)
    Entry.new(name: manifest.name || name, path: path, manifest: manifest)
  rescue StandardError => e
    # A broken manifest is information, not a crash. The operator needs to see
    # which one is broken and why.
    Entry.new(name: name, path: path, error: e.message)
  end
end

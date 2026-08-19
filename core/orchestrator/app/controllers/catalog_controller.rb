# frozen_string_literal: true

# Browsing and installing modules.
#
# Install is deliberately two steps. The permissions a module asks for are the
# whole security model, and an operator who never sees them has not approved
# anything.
class CatalogController < ApplicationController
  requires "core.modules.read"
  requires "core.modules.install", only: :create
  def index
    @entries = catalog.entries
  end

  # The review screen: what this module will be allowed to do.
  def show
    @entry = catalog.find(params[:name])
    unless @entry
      return redirect_to catalog_path, alert: "No module named #{params[:name]} in the catalogue."
    end

    @breadcrumb_leaf = @entry.title.presence || @entry.name
    @manifest = @entry.manifest
    @conflicts = conflicts_for(@manifest)
  end

  def create
    entry = catalog.find(params[:name])
    return redirect_to catalog_path, alert: "No module named #{params[:name]}." unless entry

    unless params[:approved] == "true"
      return redirect_to catalog_entry_path(entry.name), alert: "Approve the permissions to install."
    end

    result = ModuleInstaller.new(entry.manifest, registrar: ServiceRegistrar.new).call

    if result.success?
      redirect_to module_path(result.installed_module.name), notice: "#{entry.title} installed."
    else
      redirect_to catalog_entry_path(entry.name), alert: "Install failed: #{result.error}"
    end
  end

  private

  # Shown before installing rather than raised during it. An operator can act on
  # "the mail transport is already claimed"; a failed install halfway through is
  # just cleanup.
  def conflicts_for(manifest)
    return [] if manifest.nil?

    conflicts = []

    manifest.system_capabilities.each do |capability|
      next unless capability.fetch("exclusive", false)

      existing = Capability.exclusive_conflict_for(capability["interface"])
      next if existing.nil?

      conflicts << "#{existing.installed_module.name} already claims #{capability['interface']} exclusively"
    end

    manifest.provided_capabilities.each do |capability|
      taken = Capability.find_by(capability_id: capability["id"])
      conflicts << "#{capability['id']} is already provided by #{taken.installed_module.name}" if taken
    end

    conflicts
  end
end

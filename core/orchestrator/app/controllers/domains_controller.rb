# frozen_string_literal: true

class DomainsController < ApplicationController
  requires "core.domains.manage"

  # Adding a domain and deciding how much disk it may have are different
  # decisions. An operator who can serve a new hostname does not thereby get to
  # spend a disk everybody shares, which is why Storage has its own permission.
  requires "core.storage.manage", only: %i[update_storage]

  def index
    @domains = Domain.ordered
    @domain = Domain.new
    load_storage
  end

  def create
    @domain = Domain.new(domain_params)

    if @domain.save
      republish_routes
      note = apply_storage_limits(@domain.hostname)
      redirect_to domains_path, notice: "#{@domain.hostname} added and routes republished.#{note}"
    else
      @domains = Domain.ordered
      load_storage
      render :index, status: :unprocessable_entity
    end
  end

  def update
    domain = Domain.find(params[:id])
    domain.update!(primary: true)
    redirect_to domains_path, notice: "#{domain.hostname} is now the primary domain."
  end

  # The allowance for one domain: the shared pool, and what a new bucket on it
  # starts with. Both are the Storage service's numbers; this only asks.
  def update_storage
    domain = Domain.find(params[:id])

    result = storage.update_domain(domain.hostname,
                                   quota_mb: params[:quota_mb],
                                   default_bucket_quota_mb: params[:default_bucket_quota_mb])

    if result
      redirect_to domains_path, notice: "#{domain.hostname}: #{describe(result)}"
    else
      redirect_to domains_path, alert: "Storage did not accept that allowance for #{domain.hostname}."
    end
  end

  def destroy
    domain = Domain.find(params[:id])

    if Domain.count == 1
      return redirect_to domains_path, alert: "The last domain cannot be removed."
    end

    hostname = domain.hostname
    domain.destroy!
    republish_routes
    redirect_to domains_path, notice: "#{hostname} removed."
  end

  private

  def domain_params
    params.require(:domain).permit(:hostname, :label, :primary)
  end

  def storage
    @storage_client ||= StorageClient.new
  end

  # Nil when Storage did not answer. The page says so and still manages
  # domains: routing does not depend on the quota service being up.
  def load_storage
    @quotas = storage.quotas
    @usage = Array(@quotas && @quotas["domains"]).index_by { |entry| entry["domain"] }
  end

  # A domain added with an allowance gets it now rather than on the next visit
  # to another page. Silent when nothing was asked for, because most domains
  # are added without one.
  def apply_storage_limits(hostname)
    return "" unless allow?("core.storage.manage")
    return "" if params[:quota_mb].blank? && params[:default_bucket_quota_mb].blank?

    result = storage.update_domain(hostname,
                                   quota_mb: params[:quota_mb],
                                   default_bucket_quota_mb: params[:default_bucket_quota_mb])

    result ? " #{describe(result)}" : " Storage did not answer, so it has no allowance yet."
  end

  def describe(entry)
    total = entry["unlimited"] ? "no ceiling" : "#{entry['quota_mb']} MB total"
    per_bucket = entry["default_bucket_quota_mb"] ? "#{entry['default_bucket_quota_mb']} MB per new bucket" : "the global default per new bucket"

    "#{total}, #{per_bucket}."
  end

  # Every installed module needs a server block for the new domain, or the
  # domain exists in the database and nowhere else.
  def republish_routes
    result = RouteReconciler.new.call
    return if result.ok?

    flash[:alert] = "Domain saved, but routing did not fully republish: #{result.errors.join('; ')}"
  rescue StandardError => e
    flash[:alert] = "Domain saved, but the router did not reload: #{e.message}"
  end
end

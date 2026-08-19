# frozen_string_literal: true

# Storage quotas.
#
# Reading is part of running the system; changing one spends a disk everybody
# shares, so it has its own permission.
class StorageController < ApplicationController
  # A domain Storage has never heard of: no ceiling, nothing stored, and a new
  # bucket on it would take the global default.
  EMPTY_DOMAIN = { "quota_mb" => nil, "unlimited" => true, "default_bucket_quota_mb" => nil,
                   "bytes_used" => 0, "percent_used" => 0, "bucket_count" => 0 }.freeze

  requires "core.modules.read"
  requires "core.storage.manage", only: %i[update update_domain update_bucket recalculate]

  def index
    @quotas = storage.quotas
    @domains = Domain.ordered
    @domain_rows = merge_domains
  end

  def update
    result = storage.update_defaults(
      default_bucket_quota_mb: params[:default_bucket_quota_mb],
      default_domain_quota_mb: params[:default_domain_quota_mb]
    )
    redirect_to storage_path, notice: result ? "Defaults saved. New buckets get them; existing ones keep what they have." : "Could not save."
  end

  def update_domain
    result = storage.update_domain(params.require(:domain),
                                   quota_mb: params[:quota_mb],
                                   default_bucket_quota_mb: params[:default_bucket_quota_mb])
    redirect_to storage_path, notice: result ? "#{params[:domain]} updated." : "Could not update that domain."
  end

  def update_bucket
    result = storage.update_bucket(params.require(:id), params.require(:quota_mb))
    redirect_to storage_path, notice: result ? "Bucket allowance updated." : "Could not update that bucket."
  end

  def recalculate
    result = storage.recalculate
    drift = Array(result && result["domains"]).sum { |domain| domain["drift"].to_i.abs }

    redirect_to storage_path,
                notice: result ? "Recounted. #{drift.zero? ? 'The counters were correct.' : "Corrected #{number_to_human_size(drift)} of drift."}" : "Could not recount."
  end

  private

  # Storage knows a domain once something has been stored on it; the
  # Orchestrator knows one the moment it is added. Showing the union is what
  # lets an allowance be set before a module writes its first byte, and keeps
  # a leftover from a removed domain visible rather than orphaned.
  def merge_domains
    return [] if @quotas.nil?

    known = Array(@quotas["domains"]).index_by { |entry| entry["domain"] }
    served = @domains.map(&:hostname)

    (served | known.keys).map do |hostname|
      entry = known[hostname] || EMPTY_DOMAIN.merge("domain" => hostname)
      entry.merge("served" => served.include?(hostname))
    end
  end

  def storage
    @storage ||= StorageClient.new
  end

  def number_to_human_size(bytes)
    ActiveSupport::NumberHelper.number_to_human_size(bytes)
  end
end

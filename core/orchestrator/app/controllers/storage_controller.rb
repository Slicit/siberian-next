# frozen_string_literal: true

# Storage quotas.
#
# Reading is part of running the system; changing one spends a disk everybody
# shares, so it has its own permission.
class StorageController < ApplicationController
  requires "core.modules.read"
  requires "core.storage.manage", only: %i[update update_domain update_bucket recalculate]

  def index
    @quotas = storage.quotas
    @domains = Domain.ordered
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

  def storage
    @storage ||= StorageClient.new
  end

  def number_to_human_size(bytes)
    ActiveSupport::NumberHelper.number_to_human_size(bytes)
  end
end

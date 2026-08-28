# frozen_string_literal: true

# Quotas, for the Backoffice.
#
# Three levels because three questions get asked: what does a new bucket get by
# default, what is this one bucket allowed, and what is every module on this
# domain allowed between them.
module Admin
  class QuotasController < ApplicationController
    include Siberian::ServiceAuthentication
    permit_services :orchestrator

    # GET /admin/quotas
    def show
      settings = StorageSetting.current

      render json: {
        default_bucket_quota_mb: settings.default_bucket_quota_mb,
        default_domain_quota_mb: settings.default_domain_quota_mb,
        domains: DomainQuota.ordered.map { |quota| serialize_domain(quota) },
        buckets: Bucket.includes(:module_registration).order(:domain, :name).map { |bucket| serialize_bucket(bucket) }
      }
    end

    # PATCH /admin/quotas
    def update
      settings = StorageSetting.current

      if settings.update(settings_params)
        render json: { default_bucket_quota_mb: settings.default_bucket_quota_mb,
                       default_domain_quota_mb: settings.default_domain_quota_mb }
      else
        render json: { errors: settings.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /admin/quotas/domains/:domain
    def update_domain
      quota = DomainQuota.for(params[:domain])

      # Blank means no ceiling, which is a decision an operator can make and has
      # to be expressible. A very large number would be a guess wearing a
      # number's clothes.
      attributes = {
        quota_mb: params[:quota_mb].presence&.to_i,
        default_bucket_quota_mb: params[:default_bucket_quota_mb].presence&.to_i
      }

      if quota.update(attributes)
        render json: serialize_domain(quota)
      else
        render json: { errors: quota.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /admin/quotas/buckets/:id
    def update_bucket
      bucket = Bucket.find(params[:id])

      if bucket.update(quota_mb: params.require(:quota_mb).to_i)
        render json: serialize_bucket(bucket)
      else
        render json: { errors: bucket.errors.full_messages }, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotFound
      render json: { error: "no such bucket" }, status: :not_found
    end

    # POST /admin/quotas/recalculate
    #
    # Counters drift. Nothing here is clever enough to guarantee they cannot, so
    # recomputing is a button rather than a hope.
    def recalculate
      domains = DomainQuota.ordered.map do |quota|
        before = quota.bytes_used
        after = quota.recalculate!
        { domain: quota.domain, before: before, after: after, drift: after - before }
      end

      render json: { domains: domains, recalculated_at: Time.current }
    end

    private

    def settings_params
      params.permit(:default_bucket_quota_mb, :default_domain_quota_mb).compact_blank
    end

    def serialize_domain(quota)
      {
        domain: quota.domain,
        quota_mb: quota.quota_mb,
        unlimited: quota.unlimited?,
        default_bucket_quota_mb: quota.default_bucket_quota_mb,
        effective_default_mb: quota.default_bucket_quota,
        bytes_used: quota.bytes_used,
        remaining_bytes: quota.remaining_bytes,
        percent_used: quota.percent_used,
        bucket_count: Bucket.where(domain: quota.domain).count,
        recalculated_at: quota.recalculated_at
      }
    end

    def serialize_bucket(bucket)
      {
        id: bucket.id,
        name: bucket.name,
        domain: bucket.domain,
        module_name: bucket.module_registration.module_name,
        quota_mb: bucket.quota_mb,
        bytes_used: bucket.bytes_used,
        remaining_bytes: bucket.remaining_bytes,
        percent_used: bucket.percent_used
      }
    end

  end
end

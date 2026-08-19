# frozen_string_literal: true

# What every module on one domain is allowed between them.
#
# The shared pool. A module's own quota says how much of it that module may
# take; this says how much there is.
class DomainQuota < ApplicationRecord
  validates :domain, presence: true, uniqueness: true
  validates :quota_mb, numericality: { greater_than: 0 }, allow_nil: true
  validates :default_bucket_quota_mb, numericality: { greater_than: 0 }, allow_nil: true

  scope :ordered, -> { order(:domain) }

  def self.for(domain)
    find_or_create_by!(domain: domain)
  end

  # Null means no ceiling. Explicit rather than a very large number, so
  # "unlimited" reads as a decision instead of an accident.
  def unlimited? = quota_mb.nil?

  def quota_bytes = quota_mb && quota_mb * 1024 * 1024

  def remaining_bytes
    return nil if unlimited?

    [quota_bytes - bytes_used, 0].max
  end

  def would_exceed?(additional_bytes)
    return false if unlimited?

    bytes_used + additional_bytes > quota_bytes
  end

  def percent_used
    return 0 if unlimited? || quota_bytes.zero?

    ((bytes_used.to_f / quota_bytes) * 100).round(1)
  end

  # What a new bucket on this domain gets, before the module's own request is
  # taken into account. A domain override beats the global default, because the
  # reason to set one is that this domain is different.
  def default_bucket_quota
    default_bucket_quota_mb || StorageSetting.current.default_bucket_quota_mb
  end

  # Counters drift. Nothing here is clever enough to guarantee they cannot, so
  # recomputing is a button rather than a hope.
  def recalculate!
    total = Bucket.where(domain: domain).sum(:bytes_used)
    update!(bytes_used: total, recalculated_at: Time.current)
    total
  end
end

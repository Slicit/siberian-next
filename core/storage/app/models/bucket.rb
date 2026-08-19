# frozen_string_literal: true

require "digest"

# Where one module's files live for one domain.
#
# The name is derived rather than chosen, so the same (module, domain) pair
# always resolves to the same bucket without a lookup, and so a long domain
# cannot push the name past the 63 character S3 limit.
class Bucket < ApplicationRecord
  belongs_to :module_registration

  validates :domain, :name, presence: true
  validates :domain, uniqueness: { scope: :module_registration_id }

  MAX_MODULE_SEGMENT = 20

  def self.name_for(module_name, domain)
    segment = module_name.to_s[0, MAX_MODULE_SEGMENT].delete_suffix("-")
    "sib-#{segment}-#{Digest::SHA256.hexdigest(domain.to_s)[0, 8]}"
  end

  def key_for(space, path)
    cleaned = path.to_s.sub(%r{\A/+}, "")
    "#{space}/#{cleaned}"
  end

  # The bucket has its own allowance, and the domain has a pool every bucket on
  # it shares. A write has to satisfy both, and the one that refuses it is worth
  # naming: "you are full" and "the domain is full" are different problems with
  # different people to talk to.
  def over_quota?
    bytes_used >= quota_bytes
  end

  def quota_bytes
    (quota_mb || module_registration.quota_mb) * 1024 * 1024
  end

  def remaining_bytes
    [quota_bytes - bytes_used, 0].max
  end

  def percent_used
    return 0 if quota_bytes.zero?

    ((bytes_used.to_f / quota_bytes) * 100).round(1)
  end

  def domain_quota
    @domain_quota ||= DomainQuota.for(domain)
  end

  # Returns nil when the write is allowed, or the reason it is not.
  def refusal_for(additional_bytes)
    return :bucket_full if bytes_used + additional_bytes > quota_bytes
    return :domain_full if domain_quota.would_exceed?(additional_bytes)

    nil
  end

  # Both counters move together, so the domain pool cannot drift away from the
  # buckets in it one write at a time.
  def record_written!(bytes)
    transaction do
      increment!(:bytes_used, bytes)
      DomainQuota.where(domain: domain).update_all(["bytes_used = bytes_used + ?", bytes])
    end
  end

  def record_deleted!(bytes)
    transaction do
      decrement!(:bytes_used, [bytes, bytes_used].min)
      DomainQuota.where(domain: domain).update_all(["bytes_used = GREATEST(bytes_used - ?, 0)", bytes])
    end
  end
end

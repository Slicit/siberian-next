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

  def over_quota?
    bytes_used >= module_registration.quota_bytes
  end

  def remaining_bytes
    [module_registration.quota_bytes - bytes_used, 0].max
  end
end

# frozen_string_literal: true

# The one row of global storage settings.
#
# A table rather than a config file, because an operator changes this from a
# page and expects it to take effect without a deploy.
class StorageSetting < ApplicationRecord
  validates :default_bucket_quota_mb, numericality: { greater_than: 0 }

  def self.current
    first || create!(default_bucket_quota_mb: 512)
  end

  def default_bucket_quota_bytes = default_bucket_quota_mb * 1024 * 1024
end

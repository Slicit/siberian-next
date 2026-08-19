# frozen_string_literal: true

# Quotas at two levels an operator controls, plus the default that caps what a
# manifest can ask for.
#
# Usage is a counter on the row rather than a sum computed per request. The
# domain check runs on every upload, and summing every bucket on a domain per
# write is a query whose cost grows with the number of modules installed:
# installing a module should not make every other module slower.
class CreateQuotaSettings < ActiveRecord::Migration[8.1]
  def change
    # One row. A settings table with a singleton row rather than a config file,
    # because an operator changes this from a page and expects it to take effect
    # without a deploy.
    create_table :storage_settings do |t|
      t.integer :default_bucket_quota_mb, null: false, default: 512
      t.integer :default_domain_quota_mb
      t.timestamps
    end

    create_table :domain_quotas do |t|
      t.string :domain, null: false
      # Null means no ceiling for this domain. Explicit rather than a very large
      # number, so "unlimited" reads as a decision instead of an accident.
      t.integer :quota_mb
      t.integer :default_bucket_quota_mb
      t.bigint :bytes_used, null: false, default: 0
      t.datetime :recalculated_at
      t.timestamps
    end
    add_index :domain_quotas, :domain, unique: true

    # A bucket's own allowance, set when it is provisioned and adjustable
    # afterwards. Kept on the bucket rather than read from the module every
    # time, because raising one domain's allowance should not raise every
    # domain's.
    add_column :buckets, :quota_mb, :integer
    add_index :buckets, :domain
  end
end

# frozen_string_literal: true

require "test_helper"

class QuotaTest < ActiveSupport::TestCase
  MB = 1024 * 1024

  setup do
    StorageSetting.current.update!(default_bucket_quota_mb: 10)
    @registration, = ModuleRegistration.register!(
      module_name: "notes", module_uuid: "abc", spaces: %w[files], quota_mb: 500
    )
  end

  # A fresh registration each time. One module has one bucket per domain, which
  # is the design, so two buckets on one domain means two modules.
  def bucket(domain: "example.test", quota_mb: 10, bytes_used: 0, owner: nil)
    owner ||= ModuleRegistration.register!(
      module_name: "mod-#{SecureRandom.hex(4)}", module_uuid: SecureRandom.hex(4), spaces: %w[files]
    ).first

    owner.buckets.create!(
      domain: domain, name: "sib-#{SecureRandom.hex(4)}",
      quota_mb: quota_mb, bytes_used: bytes_used
    )
  end

  # The default caps the manifest ----------------------------------------

  test "a domain default beats the global one" do
    DomainQuota.for("example.test").update!(default_bucket_quota_mb: 3)

    assert_equal 3, DomainQuota.for("example.test").default_bucket_quota
    assert_equal 10, DomainQuota.for("other.test").default_bucket_quota
  end

  test "a domain with no override falls back to the global default" do
    assert_equal 10, DomainQuota.for("example.test").default_bucket_quota
  end

  # Two tiers -------------------------------------------------------------

  test "a write that fits both allowances is permitted" do
    DomainQuota.for("example.test").update!(quota_mb: 100)

    assert_nil bucket(quota_mb: 10).refusal_for(1 * MB)
  end

  test "a write past the bucket allowance is refused by the bucket" do
    DomainQuota.for("example.test").update!(quota_mb: 100)

    assert_equal :bucket_full, bucket(quota_mb: 1, bytes_used: MB - 10).refusal_for(100)
  end

  test "a write that fits the bucket but not the domain is refused by the domain" do
    DomainQuota.for("example.test").update!(quota_mb: 1, bytes_used: MB - 10)

    assert_equal :domain_full, bucket(quota_mb: 100).refusal_for(100),
                 "the shared pool has to stop a bucket that still has room of its own"
  end

  test "an unlimited domain never refuses on its own account" do
    DomainQuota.for("example.test").update!(quota_mb: nil, bytes_used: 500 * MB)

    assert_nil bucket(quota_mb: 100).refusal_for(MB)
  end

  # Counters --------------------------------------------------------------

  test "a write moves both counters together" do
    quota = DomainQuota.for("example.test")
    quota.update!(quota_mb: 100)
    target = bucket(quota_mb: 10)

    target.record_written!(5_000)

    assert_equal 5_000, target.reload.bytes_used
    assert_equal 5_000, quota.reload.bytes_used,
                 "a domain pool that only ever grows from its own writes is not a pool"
  end

  test "a delete gives the space back to both" do
    quota = DomainQuota.for("example.test")
    quota.update!(quota_mb: 100)
    target = bucket(quota_mb: 10)
    target.record_written!(5_000)

    target.record_deleted!(2_000)

    assert_equal 3_000, target.reload.bytes_used
    assert_equal 3_000, quota.reload.bytes_used
  end

  test "a counter never goes below zero" do
    quota = DomainQuota.for("example.test")
    target = bucket(quota_mb: 10, bytes_used: 100)

    target.record_deleted!(9_999)

    assert_equal 0, target.reload.bytes_used
    assert_equal 0, quota.reload.bytes_used
  end

  test "recalculating corrects drift" do
    quota = DomainQuota.for("example.test")
    bucket(bytes_used: 1_000)
    bucket(bytes_used: 2_500)
    quota.update!(bytes_used: 42)

    assert_equal 3_500, quota.recalculate!
    assert_equal 3_500, quota.reload.bytes_used
    assert quota.recalculated_at.present?
  end

  test "recalculating counts only the buckets on that domain" do
    bucket(domain: "example.test", bytes_used: 1_000)
    bucket(domain: "other.test", bytes_used: 9_000)

    assert_equal 1_000, DomainQuota.for("example.test").recalculate!
  end

  # Reporting -------------------------------------------------------------

  test "an unlimited domain reports no remaining figure rather than a huge one" do
    quota = DomainQuota.for("example.test")

    assert quota.unlimited?
    assert_nil quota.remaining_bytes
    assert_equal 0, quota.percent_used
  end

  test "percentages are what a bar is drawn from" do
    quota = DomainQuota.for("example.test")
    quota.update!(quota_mb: 10, bytes_used: 5 * MB)

    assert_in_delta 50.0, quota.percent_used, 0.1
  end
end

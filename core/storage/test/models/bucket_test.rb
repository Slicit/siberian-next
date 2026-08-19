# frozen_string_literal: true

require "test_helper"

class BucketTest < ActiveSupport::TestCase
  setup do
    @registration, = ModuleRegistration.register!(
      module_name: "demo-tasks", module_uuid: "abc123", spaces: %w[files public], quota_mb: 1
    )
  end

  test "the bucket name is derived, so the same pair always resolves the same way" do
    first = Bucket.name_for("demo-tasks", "example.test")
    second = Bucket.name_for("demo-tasks", "example.test")

    assert_equal first, second
    assert first.start_with?("sib-demo-tasks-")
  end

  test "two domains never share a bucket" do
    refute_equal Bucket.name_for("demo-tasks", "one.test"), Bucket.name_for("demo-tasks", "two.test")
  end

  test "two modules never share a bucket" do
    refute_equal Bucket.name_for("demo-tasks", "one.test"), Bucket.name_for("other-module", "one.test")
  end

  test "a long module name and a long domain still fit inside the S3 limit" do
    name = Bucket.name_for("a-very-long-module-name-that-keeps-going-and-going", "an.extremely.long.domain.example.test")

    assert_operator name.length, :<=, 63
    assert_operator name.length, :>=, 12
  end

  test "keys are namespaced by space, so one space cannot read another" do
    bucket = @registration.buckets.create!(domain: "example.test", name: "sib-demo-tasks-abcd1234")

    assert_equal "files/notes/one.txt", bucket.key_for("files", "notes/one.txt")
    assert_equal "public/logo.png", bucket.key_for("public", "/logo.png")
  end

  test "quota is exceeded only once the bytes are actually there" do
    bucket = @registration.buckets.create!(domain: "example.test", name: "sib-demo-tasks-abcd1234")

    refute bucket.over_quota?
    assert_equal 1024 * 1024, bucket.remaining_bytes

    bucket.update!(bytes_used: 1024 * 1024)
    assert bucket.over_quota?
    assert_equal 0, bucket.remaining_bytes
  end

  test "one domain cannot be provisioned twice for the same module" do
    @registration.buckets.create!(domain: "example.test", name: "sib-demo-tasks-a")

    assert_raises(ActiveRecord::RecordInvalid) do
      @registration.buckets.create!(domain: "example.test", name: "sib-demo-tasks-b")
    end
  end
end

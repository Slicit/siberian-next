# frozen_string_literal: true

require "test_helper"

class DomainTest < ActiveSupport::TestCase
  test "only one domain can be primary" do
    first = Domain.create!(hostname: "one.test", primary: true)
    second = Domain.create!(hostname: "two.test", primary: true)

    assert second.reload.primary?
    refute first.reload.primary?, "promoting a domain demotes the previous one"
  end

  test "the fingerprint is stable and short enough for a bucket name" do
    domain = Domain.create!(hostname: "example.test")

    assert_equal 8, domain.fingerprint.length
    assert_equal domain.fingerprint, Domain.create!(hostname: "other.test").tap { |d| d.hostname = "example.test" }.fingerprint
  end

  test "hostnames are unique" do
    Domain.create!(hostname: "one.test")

    assert_raises(ActiveRecord::RecordInvalid) { Domain.create!(hostname: "one.test") }
  end
end

# frozen_string_literal: true

require "test_helper"

# The AWS driver's own decisions, the ones that are not just "call the SDK".
#
# Lives here rather than in the shared lib suite because that one runs in a bare
# Ruby container with no aws-sdk gem, which is also why the drivers are required
# lazily: loading the object store abstraction must not drag S3 in for a service
# that never touches it.
class S3DriverTest < ActiveSupport::TestCase
  # Records what it was asked and answers with whatever the test set up. The
  # SDK's own stub_responses would work too, and says less about intent.
  class FakeClient
    attr_reader :calls

    def initialize(raise_on: {})
      @calls = []
      @raise_on = raise_on
    end

    def method_missing(name, **args)
      @calls << [name, args]
      error = @raise_on[name]
      raise error if error

      true
    end

    def respond_to_missing?(*) = true
  end

  def driver(client: FakeClient.new, **options)
    Siberian::ObjectStore::Drivers::S3.new(
      access_key_id: "AKIAEXAMPLE",
      secret_access_key: "secret",
      client: client,
      **options
    )
  end

  test "it reports that its credential is not scoped to one bucket" do
    provisioned = driver(region: "eu-west-3").provision("sib-example")

    refute provisioned.scoped?,
           "S3 hands out the account credential, and claiming otherwise would " \
           "promise an isolation that is not there"
    assert_equal "AKIAEXAMPLE", provisioned.access_key_id
    assert_equal "sib-example", provisioned.handle
  end

  # us-east-1 is the one region that must not appear in the location
  # constraint. Naming it is an InvalidLocationConstraint error that reads like
  # a typo in the region rather than a rule about the region.
  test "us-east-1 is created without a location constraint" do
    client = FakeClient.new
    driver(client: client, region: "us-east-1").provision("sib-example")

    _, args = client.calls.find { |name, _| name == :create_bucket }
    refute args.key?(:create_bucket_configuration)
  end

  test "every other region is named in the location constraint" do
    client = FakeClient.new
    driver(client: client, region: "eu-west-3").provision("sib-example")

    _, args = client.calls.find { |name, _| name == :create_bucket }
    assert_equal "eu-west-3", args.dig(:create_bucket_configuration, :location_constraint)
  end

  test "a bucket this account already owns is the state the caller wanted" do
    client = FakeClient.new(raise_on: { create_bucket: aws_error("BucketAlreadyOwnedByYou") })

    assert_nothing_raised { driver(client: client).provision("sib-example") }
  end

  # Different from the case above, and the difference matters: S3 bucket names
  # are one global namespace, so this one is somebody else's and will not
  # resolve itself.
  test "a bucket name taken by another account is refused, not retried" do
    client = FakeClient.new(raise_on: { create_bucket: aws_error("BucketAlreadyExists") })

    error = assert_raises(Siberian::ObjectStore::Driver::Refused) do
      driver(client: client).provision("sib-example")
    end
    assert_match(/global namespace/, error.message)
  end

  test "removing a bucket that is already gone is not an error" do
    client = FakeClient.new(raise_on: { delete_bucket: aws_error("NoSuchBucket") })

    assert driver(client: client).deprovision(name: "sib-example")
  end

  # Emptying it here would destroy a domain's files as a side effect of removing
  # a module, which is the opposite of the rule the provisioner follows.
  test "a bucket with objects in it is refused rather than emptied" do
    client = FakeClient.new(raise_on: { delete_bucket: aws_error("BucketNotEmpty") })

    assert_raises(Siberian::ObjectStore::Driver::Refused) do
      driver(client: client).deprovision(name: "sib-example")
    end
  end

  test "deprovision does not delete the credential it was handed" do
    client = FakeClient.new
    driver(client: client).deprovision(name: "sib-example", access_key_id: "AKIAEXAMPLE")

    refute client.calls.any? { |name, _| name.to_s.include?("key") },
           "the account credential is shared by every bucket, so deleting it " \
           "would take away access to all of them"
  end

  # Naming an endpoint is what says "not AWS", and every self hosted gateway
  # needs path style addressing while AWS has deprecated it.
  test "path style is inferred from whether an endpoint was named" do
    assert driver(endpoint: "http://minio:9000").force_path_style?
    refute driver.force_path_style?
  end

  test "the inference can be overridden" do
    refute driver(endpoint: "http://gateway:9000", force_path_style: false).force_path_style?
  end

  test "the public endpoint falls back to the endpoint" do
    assert_equal "http://gateway:9000", driver(endpoint: "http://gateway:9000").public_endpoint
  end

  test "provisioning without credentials says so rather than handing back nils" do
    store = Siberian::ObjectStore::Drivers::S3.new(client: FakeClient.new,
                                                   access_key_id: nil, secret_access_key: nil)

    error = assert_raises(Siberian::ObjectStore::Driver::Error) { store.provision("sib-example") }
    assert_match(/no credentials configured/, error.message)
  end

  private

  def aws_error(name)
    Aws::S3::Errors.const_get(name).new(nil, "#{name} from the test")
  end
end

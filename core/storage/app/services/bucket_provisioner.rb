# frozen_string_literal: true

# Creates the bucket and the key for one (module, domain) pair.
#
# Asks the object store driver for both and does not know which backend answers.
# Garage mints a key that reaches exactly one bucket, which is why keys are per
# bucket rather than per module: one that leaks cannot reach another domain's
# data. A backend that cannot scope a credential that tightly says so on the
# way back, and that is recorded rather than assumed.
class BucketProvisioner
  def initialize(driver: Siberian::ObjectStore.driver)
    @driver = driver
  end

  def call(registration, domain)
    existing = registration.buckets.find_by(domain: domain)
    return existing if existing&.access_key_id.present?

    name = Bucket.name_for(registration.module_name, domain)

    # The operator default caps what the manifest asked for. A manifest is
    # written by a third party, and if asking for more were enough to get more,
    # the setting would be a suggestion and the disk a shared resource with no
    # owner. A module asking for less than the default still gets what it asked
    # for: there is no reason to give it more than it wants.
    quota = DomainQuota.for(domain)
    allowance = [registration.quota_mb, quota.default_bucket_quota].compact.min

    provisioned = @driver.provision(name)

    bucket = existing || registration.buckets.build(domain: domain)
    bucket.update!(
      name: name,
      quota_mb: allowance,
      bucket_id: provisioned.handle,
      access_key_id: provisioned.access_key_id,
      secret_access_key: provisioned.secret_access_key
    )

    unless provisioned.scoped?
      # Worth saying once per bucket rather than never. On a backend that
      # cannot mint a credential per bucket, the isolation between one domain's
      # files and another's rests on this service alone, which is a different
      # and weaker promise than the one Garage makes.
      Rails.logger.info(
        "#{@driver.name}: #{name} shares an account credential; " \
        "bucket isolation is enforced by this service rather than by the store"
      )
    end

    bucket
  end

  # Deliberately not called on uninstall. Data outlives the module unless an
  # operator says otherwise: reinstalling and finding the files gone is a worse
  # surprise than a bucket left behind.
  def destroy(bucket)
    @driver.deprovision(
      name: bucket.name,
      handle: bucket.bucket_id,
      access_key_id: bucket.access_key_id
    )
    bucket.destroy!
    true
  end
end

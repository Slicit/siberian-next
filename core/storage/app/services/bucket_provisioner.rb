# frozen_string_literal: true

# Creates the bucket and the scoped key for one (module, domain) pair.
#
# The key is granted access to exactly one bucket. A key that can reach only one
# bucket cannot reach another domain's data even if it leaks, which is the whole
# reason keys are per bucket rather than per module.
class BucketProvisioner
  def initialize(admin: GarageAdmin.new)
    @admin = admin
  end

  def call(registration, domain)
    existing = registration.buckets.find_by(domain: domain)
    return existing if existing&.access_key_id.present?

    name = Bucket.name_for(registration.module_name, domain)
    bucket_id = @admin.create_bucket(name)
    key = @admin.create_key("#{name}-key")
    @admin.allow_key(bucket_id: bucket_id, access_key_id: key[:access_key_id],
                     read: true, write: true, owner: true)

    bucket = existing || registration.buckets.build(domain: domain)
    bucket.update!(
      name: name,
      bucket_id: bucket_id,
      access_key_id: key[:access_key_id],
      secret_access_key: key[:secret_access_key]
    )
    bucket
  end

  # Deliberately not called on uninstall. Data outlives the module unless an
  # operator says otherwise: reinstalling and finding the files gone is a worse
  # surprise than a bucket left behind.
  def destroy(bucket)
    @admin.delete_key(bucket.access_key_id) if bucket.access_key_id.present?
    @admin.delete_bucket(bucket.bucket_id) if bucket.bucket_id.present?
    bucket.destroy!
    true
  end
end

# frozen_string_literal: true

require "digest"

# A module the Orchestrator has told us about.
#
# The token it holds is how it proves who it is on every call. We keep only the
# digest: a leaked table should not be a leaked identity.
class ModuleRegistration < ApplicationRecord
  SPACES = %w[files tmp public].freeze

  has_many :buckets, dependent: :destroy

  validates :module_name, :module_uuid, :token_digest, presence: true
  validates :module_name, uniqueness: true
  validate :spaces_are_known

  scope :active, -> { where(revoked_at: nil) }

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # Returns the registration and the plaintext token, which is the only moment
  # the token exists in readable form.
  def self.register!(module_name:, module_uuid:, spaces:, quota_mb: 512, tmp_ttl_hours: 168)
    token = SecureRandom.urlsafe_base64(32)
    registration = find_or_initialize_by(module_name: module_name)
    registration.assign_attributes(
      module_uuid: module_uuid,
      token_digest: digest(token),
      spaces: Array(spaces),
      quota_mb: quota_mb,
      tmp_ttl_hours: tmp_ttl_hours,
      revoked_at: nil
    )
    registration.save!
    [registration, token]
  end

  def self.authenticate(token)
    return nil if token.blank?

    active.find_by(token_digest: digest(token))
  end

  def allows?(space)
    spaces.include?(space.to_s)
  end

  def revoked? = revoked_at.present?
  def quota_bytes = quota_mb * 1024 * 1024

  private

  def spaces_are_known
    unknown = Array(spaces) - SPACES
    errors.add(:spaces, "unknown: #{unknown.join(', ')}") if unknown.any?
  end
end

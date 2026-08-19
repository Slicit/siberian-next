# frozen_string_literal: true

require "digest"

# A module the Orchestrator has told us about. The token it holds is how it
# proves who it is; only the digest is stored.
class ModuleRegistration < ApplicationRecord
  has_many :provisioned_databases, dependent: :destroy
  has_many :table_grants, dependent: :destroy

  validates :module_name, :module_uuid, :token_digest, presence: true
  validates :module_name, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  def self.register!(module_name:, module_uuid:)
    token = SecureRandom.urlsafe_base64(32)
    registration = find_or_initialize_by(module_name: module_name)
    registration.assign_attributes(module_uuid: module_uuid, token_digest: digest(token), revoked_at: nil)
    registration.save!
    [registration, token]
  end

  def self.authenticate(token)
    return nil if token.blank?

    active.find_by(token_digest: digest(token))
  end

  def revoked? = revoked_at.present?

  def grant_for(target_database, table_name)
    table_grants.live.find_by(target_database: target_database, table_name: table_name)
  end
end

# frozen_string_literal: true

require "digest"

# A module the Orchestrator has told us about. The token is how it proves who it
# is; only the digest is stored.
class ModuleRegistration < ApplicationRecord
  has_many :messages, dependent: :destroy

  validates :module_name, :module_uuid, :token_digest, presence: true
  validates :module_name, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  def self.register!(module_name:, module_uuid:, daily_limit: nil)
    token = SecureRandom.urlsafe_base64(32)
    registration = find_or_initialize_by(module_name: module_name)
    registration.assign_attributes(
      module_uuid: module_uuid, token_digest: digest(token),
      daily_limit: daily_limit, revoked_at: nil
    )
    registration.save!
    [registration, token]
  end

  def self.authenticate(token)
    return nil if token.blank?

    active.find_by(token_digest: digest(token))
  end

  def revoked? = revoked_at.present?

  def sent_today
    messages.where(state: "sent").where(sent_at: Time.current.all_day).count
  end

  def over_daily_limit?
    daily_limit.present? && sent_today >= daily_limit
  end
end

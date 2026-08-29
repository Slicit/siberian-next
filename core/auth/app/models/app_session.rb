# frozen_string_literal: true

require "digest"

# One device an app account is signed in on.
#
# A browser session is short because signing in again costs a password field and
# ten seconds. A phone is signed in for months, and being asked to type a
# password because a fortnight passed is the difference between an app somebody
# uses and one they delete. So this lives long and is revoked deliberately.
#
# Which means the list of them matters. "Signed in on three devices" is
# something a person should be able to see and act on, and "this phone was
# stolen" has to be answerable without ending the session on the other two.
class AppSession < ApplicationRecord
  # Long, because the alternative is asking for a password on a phone keyboard
  # every fortnight. Bounded, because a token that never expires is a token that
  # outlives the phone it was issued to.
  DEFAULT_LIFETIME = 90.days

  # How stale `last_seen_at` is allowed to get. Every request would otherwise be
  # a write, which turns reading a page into a row update on a shared table.
  SEEN_RESOLUTION = 1.hour

  belongs_to :app_user

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }
  scope :recent, -> { order(Arel.sql("COALESCE(last_seen_at, created_at) DESC")) }

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # Returns the session and the plaintext token, which exists in readable form
  # exactly once.
  #
  # Signing in from a device that is already signed in replaces that device's
  # session rather than adding a second one. Without this, reinstalling an app
  # leaves a row nobody can identify, and the device list becomes a thing people
  # learn to ignore, which is the same as not having one.
  def self.start!(app_user:, device_id: nil, device_name: nil, platform: nil,
                  user_agent: nil, ip_address: nil, lifetime: DEFAULT_LIFETIME)
    token = SecureRandom.urlsafe_base64(32)

    transaction do
      if device_id.present?
        app_user.app_sessions.active.where(device_id: device_id).find_each(&:revoke!)
      end

      session = create!(
        app_user: app_user,
        token_digest: digest(token),
        device_id: device_id.presence,
        device_name: device_name.to_s[0, 120].presence,
        platform: platform.to_s[0, 32].presence,
        user_agent: user_agent.to_s[0, 255].presence,
        ip_address: ip_address,
        expires_at: Time.current + lifetime,
        last_seen_at: Time.current
      )

      [session, token]
    end
  end

  def self.authenticate(token)
    return nil if token.blank?

    session = active.includes(:app_user).find_by(token_digest: digest(token))
    return nil if session.nil?
    # A deactivated account keeps no live session, but a session created before
    # the deactivation would otherwise outlive it by up to three months.
    return nil unless session.app_user.active?

    session
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def expired? = expires_at <= Time.current
  def active? = revoked_at.nil? && !expired?

  # Cheap enough to call on every request, because most calls do nothing.
  def touch_seen!
    return if last_seen_at.present? && last_seen_at > SEEN_RESOLUTION.ago

    update_columns(last_seen_at: Time.current, updated_at: Time.current)
    app_user.update_columns(last_seen_at: Time.current, updated_at: Time.current)
  end

  # What a person is shown about their own devices. No token, no digest, and no
  # address precise enough to be a location.
  def to_device
    {
      id: id,
      name: device_name.presence || platform.presence || "Unknown device",
      platform: platform,
      device_id: device_id,
      last_seen_at: last_seen_at,
      created_at: created_at,
      expires_at: expires_at
    }
  end
end

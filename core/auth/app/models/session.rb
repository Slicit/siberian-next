# frozen_string_literal: true

require "digest"

# One signed-in browser, carrying a resolved answer.
#
# The token lives in a cookie scoped to the parent domain, so every module frame
# at <module>.apps.<domain> carries it without any module implementing a login.
# Only the digest is stored.
#
# The session also carries the permission set as it stood when it was resolved,
# which is what makes fine-grained checking affordable: validating a session is
# one row read, and every question asked afterwards is a set lookup.
class Session < ApplicationRecord
  DEFAULT_LIFETIME = 14.days

  belongs_to :user

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # Returns the session and the plaintext token, which exists in readable form
  # exactly once.
  def self.start!(user:, domain:, user_agent: nil, ip_address: nil, lifetime: DEFAULT_LIFETIME)
    token = SecureRandom.urlsafe_base64(32)
    permissions = user.resolved_permissions

    session = create!(
      user: user,
      token_digest: digest(token),
      domain: domain,
      user_agent: user_agent.to_s[0, 255],
      ip_address: ip_address,
      expires_at: Time.current + lifetime,
      permissions: { "granted" => permissions.to_a, "denied" => permissions.denied },
      permissions_version: user.permissions_version
    )
    [session, token]
  end

  def self.authenticate(token)
    return nil if token.blank?

    session = active.includes(:user).find_by(token_digest: digest(token))
    return nil if session.nil?
    # A deactivated account keeps no live session, but a session created before
    # the deactivation would otherwise outlive it by up to its whole lifetime.
    return nil unless session.user.active?

    session
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def expired? = expires_at <= Time.current
  def active? = revoked_at.nil? && !expired?

  # The resolved set, refreshed only when it is actually stale.
  #
  # A version comparison rather than a timestamp, because "has anything changed"
  # is the question, and a counter answers it without a clock, a broadcast, or a
  # scan for affected sessions.
  def permission_set
    refresh_permissions! if stale?

    Siberian::Permissions::Set.new(
      permissions["granted"] || [],
      denied: permissions["denied"] || []
    )
  end

  def stale?
    permissions_version != user.permissions_version
  end

  def refresh_permissions!
    resolved = user.resolved_permissions
    update!(
      permissions: { "granted" => resolved.to_a, "denied" => resolved.denied },
      permissions_version: user.permissions_version
    )
    resolved
  end
end

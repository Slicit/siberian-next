# frozen_string_literal: true

require "digest"

# One signed-in browser.
#
# The token lives in a cookie scoped to the parent domain, so every module
# frame at <module>.apps.<domain> carries it without any module implementing
# a login. Only the digest is stored.
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
    session = create!(
      user: user,
      token_digest: digest(token),
      domain: domain,
      user_agent: user_agent.to_s[0, 255],
      ip_address: ip_address,
      expires_at: Time.current + lifetime
    )
    [session, token]
  end

  def self.authenticate(token)
    return nil if token.blank?

    active.find_by(token_digest: digest(token))
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def expired? = expires_at <= Time.current
  def active? = revoked_at.nil? && !expired?
end

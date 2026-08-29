# frozen_string_literal: true

require "digest"

# One way back into one account.
#
# Short-lived, single use, and stored only as a digest, for the same reason a
# session token is: the row is readable by anybody who can read the database,
# and a reset link is a password.
class AppPasswordReset < ApplicationRecord
  # Long enough to walk to a different device and find the email, short enough
  # that a link sitting in an inbox next week is not a spare key.
  LIFETIME = 2.hours

  belongs_to :app_user

  scope :usable, -> { where(used_at: nil).where("expires_at > ?", Time.current) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  # Returns the reset and the plaintext token, which exists in readable form
  # exactly once.
  #
  # Asking again invalidates the earlier link. Somebody who clicks twice
  # because the first email was slow should find the newest link working and
  # the older one dead, rather than two live keys of which they will use one.
  def self.start!(app_user:, requested_ip: nil)
    token = SecureRandom.urlsafe_base64(32)

    transaction do
      app_user.app_password_resets.usable.update_all(used_at: Time.current)

      reset = create!(
        app_user: app_user,
        token_digest: digest(token),
        expires_at: Time.current + LIFETIME,
        requested_ip: requested_ip
      )

      [reset, token]
    end
  end

  # Why a token is no good, rather than only that it is not.
  #
  # A person who followed a link from an email they read an hour late has done
  # nothing wrong, and "that link has expired, ask for another" is the only
  # message that tells them what to do. The distinction leaks nothing: holding
  # the token is already the secret.
  def self.claim(token)
    return [nil, :unknown] if token.blank?

    reset = includes(:app_user).find_by(token_digest: digest(token))
    return [nil, :unknown] if reset.nil?
    return [nil, :used] if reset.used_at.present?
    return [nil, :expired] if reset.expires_at <= Time.current
    return [nil, :unknown] unless reset.app_user.active?

    [reset, :ok]
  end

  # Sets the password and spends the link, in one transaction, and ends every
  # device.
  #
  # Ending them is the point rather than a side effect: the reason somebody
  # resets a password is usually that somebody else knows it, and a reset that
  # leaves the other person signed in on their own phone has not done the thing
  # it was asked to do.
  def complete!(password)
    transaction do
      app_user.password = password
      return false unless app_user.save

      update!(used_at: Time.current)
      app_user.app_sessions.active.find_each(&:revoke!)
      true
    end
  end
end

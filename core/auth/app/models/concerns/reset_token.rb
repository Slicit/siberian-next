# frozen_string_literal: true

require "digest"

# A short-lived, single-use way back into an account.
#
# Two tables use this, because there are two kinds of account and keeping them
# apart is the property the second table exists to hold: an app account must
# never be able to become an operator, and the cheapest guarantee is that the
# operator machinery has nothing to attach to.
#
# One implementation, though. The rules are identical and the interesting ones
# are subtle enough that two copies would drift: asking again kills the earlier
# link, a rejected password does not spend it, and completing one ends every
# session the account had.
module ResetToken
  extend ActiveSupport::Concern

  # Long enough to walk to another device and find the email, short enough that
  # a link sitting in an inbox next week is not a spare key.
  LIFETIME = 2.hours

  included do
    scope :usable, -> { where(used_at: nil).where("expires_at > ?", Time.current) }
  end

  class_methods do
    def digest(token) = Digest::SHA256.hexdigest(token.to_s)

    # Returns the reset and the plaintext token, which exists in readable form
    # exactly once.
    #
    # Asking again invalidates the earlier link. Somebody who clicks twice
    # because the first email was slow should find the newest one working and
    # the older one dead, rather than holding two live keys of which they will
    # use one.
    def start!(owner, requested_ip: nil)
      token = SecureRandom.urlsafe_base64(32)

      transaction do
        where(owner_key => owner).usable.update_all(used_at: Time.current)

        reset = create!(
          owner_key => owner,
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
    def claim(token)
      return [nil, :unknown] if token.blank?

      reset = includes(owner_key).find_by(token_digest: digest(token))
      return [nil, :unknown] if reset.nil?
      return [nil, :used] if reset.used_at.present?
      return [nil, :expired] if reset.expires_at <= Time.current
      return [nil, :unknown] unless reset.owner.active?

      [reset, :ok]
    end

    def message_for(reason)
      case reason
      when :expired then "that link has expired, ask for another"
      when :used then "that link has already been used"
      else "that link is not valid"
      end
    end
  end

  def owner = public_send(self.class.owner_key)

  # Sets the password and spends the link, in one transaction, and ends every
  # session.
  #
  # Ending them is the point rather than a side effect: the usual reason to
  # reset a password is that somebody else knows it, and a reset that leaves
  # that person signed in has not done the thing it was asked to do.
  def complete!(password)
    transaction do
      owner.password = password
      # Returned rather than raised, and the link is not spent: spending it on a
      # password that failed validation locks somebody out for typing badly.
      return false unless owner.save

      update!(used_at: Time.current)
      owner.sessions_to_end.each(&:revoke!)
      true
    end
  end
end

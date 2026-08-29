# frozen_string_literal: true

# How often somebody has tried recently, and whether they may try again.
#
# Counted two ways at once, because either alone is trivially walked around: by
# address, so one attacker cannot walk a list of emails, and by source, so one
# attacker cannot spread the same guess across many addresses. Exceeding either
# is enough to be refused.
#
# Rows here are a counter, not evidence. They are swept, because a table that
# only grows eventually becomes the reason signing in is slow.
class AuthAttempt < ApplicationRecord
  SIGN_IN = "sign-in"
  RESET = "reset"

  # Chosen to be invisible to a person and expensive to a script.
  #
  # Sign-in is the looser of the two: somebody mistyping a password three times
  # is ordinary, and locking them out at four would generate more support than
  # it prevents. Reset is tighter because each one sends an email to somebody
  # who did not ask for it, so the limit is about the recipient rather than
  # about the account.
  LIMITS = {
    SIGN_IN => { per_identifier: 10, per_ip: 30, window: 15.minutes },
    RESET => { per_identifier: 3, per_ip: 10, window: 1.hour }
  }.freeze

  KEEP_FOR = 24.hours

  validates :kind, inclusion: { in: [SIGN_IN, RESET] }

  # No updated_at: a row here is written once and never touched again.
  self.record_timestamps = false

  def self.record!(kind:, identifier:, domain:, ip_address: nil)
    create!(kind: kind, identifier: identifier.to_s.strip.downcase,
            domain: domain, ip_address: ip_address, created_at: Time.current)
  end

  # Whether this attempt should be refused before it is even tried.
  #
  # Checked before the work rather than after, so a refused attempt costs a
  # count and not a password hash: bcrypt is deliberately slow, which makes an
  # unthrottled sign-in endpoint a way to spend somebody else's CPU.
  def self.exhausted?(kind:, identifier:, ip_address: nil)
    limits = LIMITS.fetch(kind)
    since = limits[:window].ago
    normalised = identifier.to_s.strip.downcase

    by_identifier = where(kind: kind, identifier: normalised).where(created_at: since..).count
    return true if by_identifier >= limits[:per_identifier]

    return false if ip_address.blank?

    where(kind: kind, ip_address: ip_address).where(created_at: since..).count >= limits[:per_ip]
  end

  # Cleared on success, so somebody who mistyped a password four times and then
  # got it right is not most of the way to a lockout for the next quarter hour.
  def self.forget!(kind:, identifier:)
    where(kind: kind, identifier: identifier.to_s.strip.downcase).delete_all
  end

  def self.sweep!(older_than: KEEP_FOR.ago)
    where(created_at: ...older_than).delete_all
  end
end

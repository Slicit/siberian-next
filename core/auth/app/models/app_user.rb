# frozen_string_literal: true

require "digest"

# A person who uses one domain's app.
#
# Not a smaller `User`. A `User` is an account across the whole system, and an
# operator is a `User` who was granted the permissions to run it. An `AppUser`
# is a customer of one domain, and there is no grant, role, or column here that
# could ever make one an operator. That is the security property this class
# exists to hold, so it is structural rather than checked.
#
# The same email on two domains is two people. The index says so, and this is
# the one place in the system where that is true, because everywhere else the
# tenant is a column on data rather than on identity.
class AppUser < ApplicationRecord
  include StableSubject

  subject_prefix "au"

  has_secure_password

  has_many :app_sessions, dependent: :destroy
  has_many :app_password_resets, dependent: :destroy

  # What an app account may do, fixed rather than resolved.
  #
  # It is the seeded `member` set: use the product, open any module in it, and
  # nothing in the core. Fixed because roles exist so an operator can shape what
  # staff may do, and an app account is not staff: giving it the role machinery
  # would create a path from "customer" to "operator" that has to be defended
  # forever, in exchange for flexibility nobody asked for.
  #
  # A module that wants finer control over its own users has its own tables and
  # its own opinion. That is a module's business, not the core's.
  PERMISSIONS = %w[app.use module.*.use].freeze

  validates :domain, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP },
                    uniqueness: { scope: :domain, case_sensitive: false }
  validates :password, length: { minimum: 8 }, allow_nil: true

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }
  normalizes :domain, with: ->(domain) { domain.to_s.strip.downcase }

  # Deleted accounts are excluded everywhere `active` is used, which is every
  # path that can sign somebody in.
  scope :active, -> { where(active: true, deleted_at: nil) }
  scope :on, ->(domain) { where(domain: domain.to_s.strip.downcase) }
  scope :ordered, -> { order(:email) }

  def display_name
    name.presence || email.split("@").first
  end

  def permission_set
    Siberian::Permissions::Set.new(PERMISSIONS)
  end

  # Whether this account has proved it can read the address it signed up with.
  #
  # Recorded and reported, not enforced. Blocking sign-in on it would mean a
  # broken mail transport locks every new account out of a product that was
  # working, which is a worse failure than an unverified address. A module that
  # wants to care reads `verified` from the identity and decides for itself.
  def verified? = verified_at.present?

  # Returns the plaintext token, which exists in readable form exactly once.
  def start_verification!
    token = SecureRandom.urlsafe_base64(32)
    update!(verification_digest: Digest::SHA256.hexdigest(token), verified_at: nil)
    token
  end

  def self.verify!(token)
    return nil if token.blank?

    account = find_by(verification_digest: Digest::SHA256.hexdigest(token.to_s))
    return nil if account.nil?

    # The digest goes with it. A verification link is single use for the same
    # reason a reset link is: one that keeps working is a second credential
    # sitting in a mailbox.
    account.update!(verified_at: Time.current, verification_digest: nil)
    account
  end

  # What a password reset ends. Named here rather than reached for, because the
  # two kinds of account keep their sessions in different tables.
  def sessions_to_end = app_sessions.active

  # Ended by the person whose account it is.
  #
  # The row survives, and keeps its address, because every module keys its rows
  # by email: freeing the address would hand the next person to sign up with it
  # the previous one's tasks and notes. Being unable to reuse an address is a
  # smaller harm than inheriting a stranger's data.
  #
  # What actually goes: the ability to sign in, every session on every device,
  # the password, and the name. What remains is an address that cannot be
  # claimed and a date.
  def erase!
    transaction do
      app_sessions.find_each(&:revoke!)
      app_password_resets.usable.update_all(used_at: Time.current)

      update!(
        deleted_at: Time.current,
        active: false,
        name: nil,
        verified_at: nil,
        verification_digest: nil,
        # A password nobody can present. `has_secure_password` will not accept a
        # nil, and leaving the old digest in place would leave a credential for
        # an account that is supposed to be gone.
        password: SecureRandom.urlsafe_base64(48)
      )
    end
  end

  def deleted? = deleted_at.present?

  def deactivate!
    transaction do
      update!(active: false, deactivated_at: Time.current)
      # An inactive account with a live session on a phone somewhere is an
      # active account. Every device goes, not the one that asked.
      app_sessions.active.find_each(&:revoke!)
    end
  end

  def reactivate!
    update!(active: true, deactivated_at: nil)
  end

  # What every other service is told. The same shape a core account produces, so
  # a module identifying the person in front of it does not have to know which
  # kind it got, and `operator` is false because it is a fact about this class
  # rather than a value somebody could set.
  def to_identity
    permissions = permission_set

    {
      # The stable name. `id` is kept because callers ask for it, but a module
      # keys its rows by this: an address is how somebody signs in, not who
      # they are, and the two id sequences overlap between operators and app
      # users.
      subject: subject,
      id: id,
      email: email,
      name: display_name,
      active: active,
      operator: false,
      app_user: true,
      verified: verified?,
      domain: domain,
      permissions: permissions.to_a,
      denied: permissions.denied
    }
  end
end

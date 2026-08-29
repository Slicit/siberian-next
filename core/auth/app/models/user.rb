# frozen_string_literal: true

# A person. One account across the whole system: the Backoffice, the Base App,
# and every module see the same user, which is the point of shipping auth in the
# core rather than letting every module invent it.
class User < ApplicationRecord
  has_secure_password

  has_many :sessions, dependent: :destroy
  has_many :user_password_resets, dependent: :destroy
  has_many :role_assignments, dependent: :destroy
  has_many :roles, through: :role_assignments
  has_many :permission_grants, dependent: :destroy

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:email) }

  def display_name
    name.presence || email.split("@").first
  end

  # Resolution. This is the expensive path, and it runs once per session rather
  # than once per question.
  #
  # Two queries and a union: every permission from every role the person holds,
  # plus their own allow grants, minus nothing (deny is carried separately,
  # because a deny has to survive being unioned with an allow).
  def resolved_permissions
    granted = roles.flat_map { |role| role.permission_list }
    granted += permission_grants.allowing.pluck(:permission)
    denied = permission_grants.denying.pluck(:permission)

    Siberian::Permissions::Set.new(granted, denied: denied)
  end

  # Anything that could change this person's answers bumps the counter. Sessions
  # carry the version they resolved at, so a mismatch means re-resolve. No
  # broadcast, no session hunting, and no cache that can be wrong without
  # anybody being able to tell.
  def bump_permissions_version!
    increment!(:permissions_version)
  end

  def sessions_to_end = sessions.active

  def deactivate!
    transaction do
      update!(active: false, deactivated_at: Time.current)
      # An inactive account with live sessions is an active account.
      sessions.active.find_each(&:revoke!)
    end
  end

  def reactivate!
    update!(active: true, deactivated_at: nil)
  end

  # Kept as a derived answer rather than a column, so there is one definition of
  # what an operator is and it lives in the permission set.
  def operator?
    resolved_permissions.any?("core.modules.read", "core.users.read", "core.roles.manage")
  end

  # What every other service is told about this user. Deliberately small: a
  # module has no business knowing the password digest or the OTP secret, and
  # the easiest way to guarantee that is to have one place that decides.
  def to_identity(permissions = nil)
    permissions ||= resolved_permissions

    {
      id: id,
      email: email,
      name: display_name,
      active: active,
      # Retained because callers still ask, but now it is derived from
      # permissions rather than a boolean somebody set by hand.
      operator: permissions.any?("core.modules.read", "core.users.read", "core.roles.manage"),
      permissions: permissions.to_a,
      denied: permissions.denied
    }
  end
end

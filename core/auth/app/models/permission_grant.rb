# frozen_string_literal: true

# A permission attached to one person, outside any role.
#
# Both directions, and the second is the one that earns its keep: "an operator,
# except for this" is a real shape, and expressing it by carefully not granting
# something is fragile, because the next role that grants it silently undoes the
# intent.
class PermissionGrant < ApplicationRecord
  EFFECTS = %w[allow deny].freeze

  belongs_to :user
  belongs_to :granted_by, class_name: "User", optional: true

  validates :permission, presence: true
  validates :effect, inclusion: { in: EFFECTS }
  validates :permission, uniqueness: { scope: %i[user_id effect] }

  scope :allowing, -> { where(effect: "allow") }
  scope :denying, -> { where(effect: "deny") }

  after_commit :invalidate_user

  def allow? = effect == "allow"
  def deny? = effect == "deny"

  def to_s = "#{effect} #{permission}"

  private

  def invalidate_user
    user.bump_permissions_version!
  end
end

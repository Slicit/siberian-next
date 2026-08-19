# frozen_string_literal: true

# One person holding one role.
class RoleAssignment < ApplicationRecord
  belongs_to :user
  belongs_to :role
  belongs_to :granted_by, class_name: "User", optional: true

  validates :role_id, uniqueness: { scope: :user_id }

  after_commit :invalidate_user

  private

  def invalidate_user
    user.bump_permissions_version!
  end
end

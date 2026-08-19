# frozen_string_literal: true

# A bundle of permissions with a name.
#
# Roles exist because granting eleven permissions to each of forty people is not
# access control, it is data entry with a chance of a mistake on every line.
class Role < ApplicationRecord
  has_many :role_assignments, dependent: :destroy
  has_many :users, through: :role_assignments

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validate :permissions_are_strings

  scope :ordered, -> { order(:name) }

  normalizes :name, with: ->(name) { name.to_s.strip.downcase }

  # Changing what a role grants changes the answers for everybody holding it, so
  # every one of them has to re-resolve.
  after_update_commit :invalidate_holders
  after_destroy_commit :invalidate_holders

  def self.seed_defaults!
    Siberian::Permissions::SEEDED_ROLES.each do |name, attributes|
      role = find_or_initialize_by(name: name)
      next if role.persisted?

      role.update!(
        description: attributes[:description],
        permissions: attributes[:permissions],
        seeded: true
      )
    end
  end

  def permission_list = Array(permissions).map(&:to_s)

  def grants?(permission)
    Siberian::Permissions::Set.new(permission_list).allow?(permission)
  end

  def to_s = name

  private

  def permissions_are_strings
    return if Array(permissions).all? { |permission| permission.is_a?(String) && !permission.strip.empty? }

    errors.add(:permissions, "must be a list of non-empty strings")
  end

  def invalidate_holders
    User.where(id: role_assignments.select(:user_id)).find_each(&:bump_permissions_version!)
  end
end

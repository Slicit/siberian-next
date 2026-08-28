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
  #
  # One registration listing both events, not two registrations naming the same
  # method: Rails deduplicates commit callbacks by filter, so the second
  # silently replaces the first and only the last one declared ever runs.
  after_commit :invalidate_holders, on: %i[update destroy]

  def self.seed_defaults!
    Siberian::Permissions::SEEDED_ROLES.each do |name, attributes|
      role = find_or_initialize_by(name: name)
      next if role.persisted?

      role.update!(
        description: attributes[:description],
        permissions: attributes[:permissions],
        seeded_permissions: attributes[:permissions],
        seeded: true
      )
    end
  end

  # Delivers permissions the catalogue gained after this role was last seeded.
  #
  # `seed_defaults!` deliberately skips a role that already exists, which is
  # what stops it trampling an operator's edits, and also what stops a new
  # permission ever reaching an installation that has already been seeded.
  # Neither re-seeding wholesale nor adding every catalogue permission the role
  # lacks is right: the first discards the operator's opinion, the second
  # re-adds exactly what the operator removed.
  #
  # The difference against the previous snapshot is the only set that is
  # unambiguous, because a permission in it did not exist the last time anybody
  # could have had an opinion about it.
  #
  # Returns what it added, per role, so the caller can say what happened.
  def self.reconcile_seeded!
    added = {}

    Siberian::Permissions::SEEDED_ROLES.each do |name, attributes|
      role = find_by(name: name, seeded: true)
      next if role.nil?

      catalogue = Array(attributes[:permissions]).map(&:to_s)
      previous = role.seeded_permission_list
      fresh = catalogue - previous
      # Anything already covered is not an addition. A role holding `*` gains
      # nothing from a new permission, and saying it did would be noise.
      grants = fresh.reject { |permission| role.grants?(permission) }

      # The snapshot moves to the current catalogue either way. A permission
      # this role already covers has still been offered, and offering it twice
      # would re-add it after an operator narrowed the wildcard.
      if grants.empty?
        role.update!(seeded_permissions: catalogue) if previous != catalogue
        next
      end

      role.update!(permissions: role.permission_list + grants, seeded_permissions: catalogue)
      added[role.name] = grants
    end

    added
  end

  def permission_list = Array(permissions).map(&:to_s)

  def seeded_permission_list = Array(seeded_permissions).map(&:to_s)

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

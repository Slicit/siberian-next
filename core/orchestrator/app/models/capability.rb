# frozen_string_literal: true

# Something a module offers the rest of the system.
#
# Two kinds, because they extend different things:
#
#   system   extends the core. Implements a named interface (mail.transport.v1)
#            that the core already knows how to call, so mail, authentication,
#            or caching can be answered by a module instead of by the built-in
#            service. No UI, no area.
#   feature  extends the product. A page or fragment the Base App lists or
#            links in a named area.
#
# They share one table because they share an id namespace and because discovery
# matches a module's `consumes` against both kinds without caring which it finds.
class Capability < ApplicationRecord
  KINDS = %w[system feature].freeze

  # The core's own services register at this priority, so any module that
  # implements the same interface outranks them unless it asks not to.
  CORE_PRIORITY = 1000

  belongs_to :installed_module

  validates :capability_id, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :area, :path, presence: true, if: :feature?
  validates :interface, :endpoint, presence: true, if: :system?

  scope :system, -> { where(kind: "system") }
  scope :features, -> { where(kind: "feature") }
  scope :in_area, ->(area) { features.where(area: area).order(:position, :title) }
  scope :ordered, -> { order(:kind, :area, :position, :title) }

  # Best implementation first. Priority is ascending because "priority 1" ought
  # to mean "ahead of priority 100", which is the reading everyone expects.
  scope :implementing, ->(interface) { system.where(interface: interface).order(:priority, :id) }

  def system? = kind == "system"
  def feature? = kind == "feature"

  # Capability ids are dotted: <module>.<subject>.<role>.
  def subject = capability_id.split(".")[1]
  def role = capability_id.split(".").last

  # Where a feature capability is reachable from a browser, for a given domain.
  # System capabilities are never reached this way: the core calls them over the
  # internal network, by module short name.
  def url_for(domain)
    raise "system capabilities have no browser URL" if system?

    "https://#{installed_module.origin_for(domain)}#{path}"
  end

  # Where the core calls a system capability. The module short name resolves on
  # the module network, so this never names a container.
  def internal_url
    raise "feature capabilities are not called by the core" if feature?

    "http://#{installed_module.name}#{endpoint}"
  end

  # Two modules claiming the same interface exclusively is a conflict an
  # operator has to resolve, not something to decide silently at install time.
  def self.exclusive_conflict_for(interface, excluding: nil)
    scope = system.where(interface: interface, exclusive: true)
    scope = scope.where.not(installed_module_id: excluding) if excluding
    scope.first
  end
end

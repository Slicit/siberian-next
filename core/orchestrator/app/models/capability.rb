# frozen_string_literal: true

# Something a module offers the rest of the system.
#
# The Base App reads these to decide what appears where: `area` names the
# region of the shell, and everything in the same area is listed together.
class Capability < ApplicationRecord
  belongs_to :installed_module

  validates :capability_id, presence: true, uniqueness: true
  validates :area, :title, :path, presence: true

  scope :in_area, ->(area) { where(area: area).order(:position, :title) }
  scope :ordered, -> { order(:area, :position, :title) }

  # Capability ids are dotted: <module>.<subject>.<role>.
  def subject = capability_id.split(".")[1]
  def role = capability_id.split(".").last

  # Where this capability is reachable from a browser, for a given domain.
  def url_for(domain)
    "https://#{installed_module.origin_for(domain)}#{path}"
  end
end

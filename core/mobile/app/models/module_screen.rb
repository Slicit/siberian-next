# frozen_string_literal: true

# One feature capability a module renders natively.
#
# Matched to the module's own feature capability by id, so a module can ship a
# native screen for one and let another fall back to its web UI. The fallback is
# not a lesser path: a module whose UI is a form does not improve by compiling.
class ModuleScreen < ApplicationRecord
  belongs_to :module_registration

  validates :capability, presence: true, uniqueness: { scope: :module_registration_id }
  validates :component, presence: true

  def as_contribution
    {
      capability: capability,
      component: component,
      title: title,
      icon: icon,
      module: module_registration.module_name
    }
  end
end

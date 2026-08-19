# frozen_string_literal: true

# A native capability a module says it needs.
#
# Stored as what the module asked for, never as what it got. Whether the
# capability is on is decided per app, by an operator, in app_capabilities: an
# operator setting caps a manifest, never the reverse.
class ModuleRequirement < ApplicationRecord
  belongs_to :module_registration

  validates :capability, presence: true,
                         uniqueness: { scope: :module_registration_id },
                         inclusion: { in: Siberian::MobileCapabilities::IDS,
                                      message: "is not a capability this core can build" }
end

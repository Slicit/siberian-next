# frozen_string_literal: true

# A capability a module would like to use if something provides it.
#
# Kept apart from Capability so discovery can match the two sides without
# either module naming the other. An unmatched request is not an error; it is
# a feature that stays switched off.
class CapabilityRequest < ApplicationRecord
  belongs_to :installed_module

  validates :capability_id, presence: true

  def provider
    Capability.find_by(capability_id: capability_id)
  end

  def satisfied? = provider.present?
end

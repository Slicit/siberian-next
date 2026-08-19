# frozen_string_literal: true

# One native capability, switched on for one app.
#
# The row exists because somebody decided. Absence is off, which is why there is
# no `enabled: false` default row for every capability in the catalogue: a table
# full of rows nobody chose says nothing about what was chosen.
class AppCapability < ApplicationRecord
  OPERATOR = "operator"
  MODULE = "module"

  belongs_to :mobile_app

  validates :capability, presence: true,
                         uniqueness: { scope: :mobile_app_id },
                         inclusion: { in: Siberian::MobileCapabilities::IDS,
                                      message: "is not a capability this core can build" }
  validates :source, inclusion: { in: [OPERATOR, MODULE] }

  scope :enabled, -> { where(enabled: true) }

  def definition = Siberian::MobileCapabilities.find(capability)
  def label = definition&.fetch(:label) || capability
  def package = definition&.fetch(:package)

  # Secrets go to the builder and never back to a page. A key an operator can
  # read off a screen is a key that leaves with whoever read it.
  def redacted_settings
    secret_keys = Array(definition&.fetch(:settings)).select { |s| s[:secret] }.map { |s| s[:key] }

    settings.to_h.transform_keys(&:to_s).map do |key, value|
      [key, secret_keys.include?(key) && value.to_s.present? ? "set" : value]
    end.to_h
  end
end

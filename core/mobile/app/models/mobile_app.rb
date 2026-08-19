# frozen_string_literal: true

# One app per domain.
#
# The domain is the tenant boundary everywhere else in this system, so it is the
# key here too: containers are shared across domains and data is not, and an app
# is data.
class MobileApp < ApplicationRecord
  has_many :app_capabilities, dependent: :destroy
  has_many :builds, dependent: :destroy

  validates :domain, presence: true, uniqueness: true
  validates :name, presence: true
  validates :bundle_identifier, presence: true, uniqueness: true,
                                format: { with: /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/,
                                          message: "must look like com.example.app" }

  scope :ordered, -> { order(:domain) }

  # A sensible identifier from a hostname, reversed the way both stores expect.
  # siberian.test becomes test.siberian, and a label that cannot start an
  # identifier gets a prefix rather than being dropped, because two domains must
  # not collapse into one bundle id.
  def self.bundle_identifier_for(domain)
    domain.to_s.downcase.split(".").reverse.map do |label|
      cleaned = label.gsub(/[^a-z0-9]/, "_")
      cleaned.match?(/\A[a-z]/) ? cleaned : "d#{cleaned}"
    end.join(".")
  end

  # What the app is actually built with. A capability is on only if a row says
  # so: absence is off, and off is the default, because every one of these is
  # something the app can then do to somebody.
  def enabled_capabilities
    app_capabilities.where(enabled: true).pluck(:capability)
  end

  # A capability that is enabled but missing a setting it cannot work without is
  # not enabled, it is half configured. Saying so is the difference between a
  # build that fails in Gradle and a page that answers the question.
  def misconfigured_capabilities
    app_capabilities.where(enabled: true).filter_map do |row|
      missing = Siberian::MobileCapabilities.required_settings(row.capability)
                                            .map { |setting| setting[:key] }
                                            .reject { |key| row.settings[key].to_s.present? }
      next if missing.empty?

      { capability: row.capability, missing: missing }
    end
  end

  def latest_build = builds.order(created_at: :desc).first
end

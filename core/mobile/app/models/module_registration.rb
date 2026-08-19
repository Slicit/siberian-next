# frozen_string_literal: true

# A module, as the Mobile service knows it.
#
# Registered by the Orchestrator at install time, the same shape Storage and
# Mailer use. A module cannot register itself: what it ships natively runs
# inside somebody's app, and that is approved before it exists here.
class ModuleRegistration < ApplicationRecord
  WEBVIEW = "webview"
  NONE = "none"

  has_many :module_screens, dependent: :destroy
  has_many :module_requirements, dependent: :destroy

  validates :module_name, presence: true, uniqueness: true
  validates :module_uuid, presence: true
  validates :fallback, inclusion: { in: [WEBVIEW, NONE] }

  scope :live, -> { where(revoked_at: nil) }
  scope :ordered, -> { order(:module_name) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  def self.authenticate(token)
    return nil if token.to_s.empty?

    live.find_by(token_digest: digest(token))
  end

  def self.issue_token
    SecureRandom.urlsafe_base64(32)
  end

  def ships_native? = module_screens.any?
  def required_capabilities = module_requirements.pluck(:capability)

  # What this module contributes to one app: its native screens if every
  # capability it requires is enabled, and its fallback if not.
  #
  # A module whose requirement is unmet is not an error. It is a feature that
  # stays switched off, which is what an unmatched capability does everywhere
  # else in this system.
  def contribution_for(enabled)
    missing = required_capabilities - Array(enabled)

    if ships_native? && missing.empty?
      { kind: "native", screens: module_screens.map { |screen| screen.as_contribution } }
    elsif fallback == WEBVIEW
      { kind: "webview", reason: missing.any? ? "requires #{missing.join(', ')}" : nil }
    else
      { kind: "none", reason: missing.any? ? "requires #{missing.join(', ')}" : "ships nothing native" }
    end
  end
end

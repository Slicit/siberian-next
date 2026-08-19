# frozen_string_literal: true

# An append-only record of what the Orchestrator did.
#
# Installing a module touches an engine, a database, a storage service, and a
# router. When it goes wrong the question is always which step, and a status
# column on the module cannot answer that.
class Activity < ApplicationRecord
  belongs_to :installed_module, optional: true

  OUTCOMES = %w[started succeeded failed].freeze

  validates :action, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :recent, -> { order(created_at: :desc) }

  def self.record(action, installed_module: nil, outcome: "succeeded", detail: nil, **context)
    create!(
      action: action,
      installed_module: installed_module,
      outcome: outcome,
      detail: detail,
      context: context
    )
  end

  def failed? = outcome == "failed"
end

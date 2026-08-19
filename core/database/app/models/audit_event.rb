# frozen_string_literal: true

# The audit trail.
#
# Append-only by convention and by the absence of any code that updates it: a
# trail somebody can edit is not a trail. Every credential issued and every
# system table read lands here, including the refusals, which are usually the
# interesting ones.
class AuditEvent < ApplicationRecord
  OUTCOMES = %w[allowed refused failed].freeze

  validates :module_name, :action, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :recent, -> { order(occurred_at: :desc) }
  scope :refusals, -> { where(outcome: "refused") }
  scope :for_module, ->(name) { where(module_name: name) }

  def self.record!(module_name:, action:, domain: nil, subject: nil, outcome: "allowed",
                   row_count: nil, detail: nil, **context)
    create!(
      module_name: module_name,
      domain: domain,
      action: action,
      subject: subject,
      outcome: outcome,
      row_count: row_count,
      detail: detail,
      context: context,
      occurred_at: Time.current
    )
  end

  def refused? = outcome == "refused"
end

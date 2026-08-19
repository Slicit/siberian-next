# frozen_string_literal: true

# An access right an operator approved at install time.
#
# Nothing outside this table is reachable by the module. This is the Android
# model: the manifest asks, a human approves, and the core mints credentials
# scoped to exactly what was approved.
class Grant < ApplicationRecord
  belongs_to :installed_module

  KINDS = %w[database storage mail module].freeze

  validates :kind, inclusion: { in: KINDS }

  scope :databases, -> { where(kind: "database") }
  scope :storage, -> { where(kind: "storage") }

  def approved? = approved_at.present?
  def per_domain? = scope == "per_domain"

  # Read is the default grant on something the module does not own.
  def read_only? = access == "read"
end

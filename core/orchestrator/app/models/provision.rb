# frozen_string_literal: true

# A resource provisioned for one (module, domain) pair.
#
# This table is where "isolate data, not runners" stops being a principle and
# starts being rows: one database and one bucket per domain, for a set of
# containers that exists once.
class Provision < ApplicationRecord
  belongs_to :installed_module
  belongs_to :domain

  KINDS = %w[database storage].freeze
  STATES = %w[pending ready failed].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :state, inclusion: { in: STATES }
  validates :identifier, presence: true

  scope :ready, -> { where(state: "ready") }

  def ready? = state == "ready"
end

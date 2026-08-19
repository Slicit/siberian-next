# frozen_string_literal: true

# What the engine was asked to create for a module.
#
# engine_id is whatever the current engine calls this container. It is stored
# for convenience and never treated as stable across engines: the name is the
# identity the core relies on.
class ModuleContainer < ApplicationRecord
  belongs_to :installed_module

  ROLES = %w[http worker datastore].freeze
  STATES = %w[absent running stopped restarting dead].freeze

  validates :service, :name, :image, :role, presence: true
  validates :role, inclusion: { in: ROLES }
  validates :name, uniqueness: true

  scope :routable, -> { where(role: "http") }

  def http? = role == "http"
  def datastore? = role == "datastore"

  def healthy? = state == "running"
end

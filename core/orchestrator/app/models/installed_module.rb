# frozen_string_literal: true

# One installation of a module.
#
# Named InstalledModule because Module is Ruby's own, and shadowing it inside a
# Rails app costs more than the nicer name is worth.
class InstalledModule < ApplicationRecord
  STATUSES = %w[pending installing running degraded stopped failed removing].freeze

  has_many :module_containers, dependent: :destroy
  has_many :capabilities, dependent: :destroy
  has_many :capability_requests, dependent: :destroy
  has_many :grants, dependent: :destroy
  has_many :provisions, dependent: :destroy
  has_many :activities, dependent: :nullify

  validates :uuid, :name, :version, presence: true, uniqueness: { case_sensitive: false }
  validates :status, inclusion: { in: STATUSES }

  scope :ordered, -> { order(:name) }
  scope :live, -> { where(status: %w[running degraded]) }

  STATUSES.each do |value|
    define_method("#{value}?") { status == value }
  end

  # The parsed manifest, rebuilt from what was stored at install time. The file
  # on disk may have changed since; this is what was actually agreed to.
  def parsed_manifest
    @parsed_manifest ||= Siberian::Contracts::Manifest.new(manifest)
  end

  def entry_container
    module_containers.find_by(service: entry_service)
  end

  def origin_for(domain)
    "#{origin.presence || name}.apps.#{domain}"
  end

  # Health is the worst state among the containers that are supposed to run.
  def derived_status
    states = module_containers.pluck(:state)
    return "stopped" if states.empty? || states.all? { |s| s == "absent" }
    return "running" if states.all? { |s| s == "running" }
    return "failed" if states.any? { |s| s == "dead" }

    "degraded"
  end

  # Live means the core may route work to it. A degraded module still answers,
  # so it stays live; a failed or stopped one does not.
  def live? = %w[running degraded].include?(status)

  def system_capabilities = capabilities.system
  def feature_capabilities = capabilities.features

  def short_uuid = uuid.to_s[0, 8]
end

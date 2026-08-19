# frozen_string_literal: true

# A domain the system serves. Containers are shared across every domain; data
# is not. See LOGBOOK.md, "Isolate data, not runners".
class Domain < ApplicationRecord
  has_many :provisions, dependent: :destroy

  validates :hostname, presence: true, uniqueness: true

  scope :ordered, -> { order(primary: :desc, hostname: :asc) }

  before_save :ensure_single_primary

  def self.primary_domain
    find_by(primary: true) || ordered.first
  end

  def to_s = hostname

  # A short, stable fingerprint of the hostname. Used to keep provisioned
  # names inside length limits without truncating a domain into ambiguity.
  def fingerprint
    Digest::SHA256.hexdigest(hostname)[0, 8]
  end

  private

  def ensure_single_primary
    return unless primary? && primary_changed?

    Domain.where.not(id: id).update_all(primary: false)
  end
end

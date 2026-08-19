# frozen_string_literal: true

# Permission to read one named table in a database this module does not own.
#
# Deliberately not a Postgres grant. The core databases live on a different
# cluster from module data, and more importantly a direct connection is
# unobservable: routing these reads through the service is what makes the audit
# trail possible at all.
class TableGrant < ApplicationRecord
  belongs_to :module_registration

  ACCESS = %w[read].freeze

  validates :target_database, :table_name, presence: true
  validates :access, inclusion: { in: ACCESS }

  scope :live, -> { where(revoked_at: nil) }

  def revoked? = revoked_at.present?
  def approved? = approved_at.present?

  def to_s = "#{access} #{target_database}.#{table_name}"
end

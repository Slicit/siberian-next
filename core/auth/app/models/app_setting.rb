# frozen_string_literal: true

# What a domain's app allows, for the small number of things that are policy
# rather than data.
#
# One row per domain, created on first read rather than at domain creation:
# Auth is not told when a domain appears, and a settings table that has to be
# kept in step with one it cannot see is a table that drifts.
class AppSetting < ApplicationRecord
  validates :domain, presence: true, uniqueness: true

  normalizes :domain, with: ->(domain) { domain.to_s.strip.downcase }

  # Closed unless somebody opened it. A default of open would mean a domain
  # accepts signups from strangers before its operator has been asked, and the
  # first anybody hears of it is the account list.
  def self.for(domain)
    find_or_create_by!(domain: domain.to_s.strip.downcase)
  rescue ActiveRecord::RecordNotUnique
    # Two first requests at once. The row exists either way, which is all the
    # caller wanted.
    find_by!(domain: domain.to_s.strip.downcase)
  end

  def to_h
    { domain: domain, registration_open: registration_open }
  end
end

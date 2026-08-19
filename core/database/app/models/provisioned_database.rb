# frozen_string_literal: true

require "digest"

# One database and one Postgres role, belonging to one (module, domain) pair.
#
# The module connects to Postgres directly with these credentials. Postgres
# roles are the isolation, which is what they are for, and nothing sits in the
# hot path of a module reading its own data.
class ProvisionedDatabase < ApplicationRecord
  # The password has to be re-servable: a module container restarts and asks
  # again, and several replicas of the same module must get the same answer.
  # So it is stored, and stored encrypted.
  encrypts :encrypted_password

  belongs_to :module_registration

  validates :domain, :logical_name, :database_name, :role_name, presence: true

  scope :ready, -> { where(state: "ready") }

  MAX_MODULE_SEGMENT = 16

  # Derived rather than chosen, so the same pair always resolves to the same
  # names, and so a long domain cannot push past Postgres's 63 byte identifier
  # limit and collide with a neighbour.
  def self.names_for(module_name, domain, logical_name)
    segment = module_name.to_s.tr("-", "_")[0, MAX_MODULE_SEGMENT].delete_suffix("_")
    fingerprint = Digest::SHA256.hexdigest("#{domain}/#{logical_name}")[0, 8]
    {
      database_name: "sib_#{segment}_#{fingerprint}",
      role_name: "sibrole_#{segment}_#{fingerprint}"
    }
  end

  def ready? = state == "ready"

  # What a module is told. The host is the alias the module data cluster answers
  # to on that module's own network, never a container name.
  def connection_details
    host = ENV.fetch("MODULEDB_HOST", "db")
    port = ENV.fetch("MODULEDB_PORT", "5432")

    {
      host: host,
      port: port.to_i,
      database: database_name,
      username: role_name,
      password: encrypted_password,
      url: "postgres://#{role_name}:#{encrypted_password}@#{host}:#{port}/#{database_name}"
    }
  end
end

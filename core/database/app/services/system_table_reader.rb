# frozen_string_literal: true

require "pg"

# Reads an allowlisted table in a database the calling module does not own.
#
# Every read goes through here rather than through a Postgres grant, for two
# reasons. The core databases live on a different cluster from module data, so
# a direct grant is not even possible. More importantly, a direct connection is
# unobservable: routing these reads through the service is what makes the audit
# trail exist at all.
#
# There is no SQL parameter anywhere in this API. A module names a table it was
# granted and gets rows back; it cannot express a query, so it cannot express a
# query that escapes the grant.
class SystemTableReader
  class Error < StandardError; end
  class NotGranted < StandardError; end
  class UnknownDatabase < StandardError; end

  MAX_LIMIT = 500
  DEFAULT_LIMIT = 100

  # Logical name to connection. A module names the logical database, never a
  # host, so moving the configuration store is a change here and nowhere else.
  def self.databases
    {
      "core.configuration" => ENV["CORE_CONFIGURATION_URL"],
      "core.auth" => ENV["CORE_AUTH_URL"]
    }.compact
  end

  def initialize(registration, domain: nil)
    @registration = registration
    @domain = domain
  end

  def read(target_database, table_name, limit: DEFAULT_LIMIT)
    grant = @registration.grant_for(target_database, table_name)

    if grant.nil?
      audit("system_table.refused", target_database, table_name, outcome: "refused",
            detail: "no live grant for this table")
      raise NotGranted, "#{@registration.module_name} has no grant for #{target_database}.#{table_name}"
    end

    url = self.class.databases[target_database]
    if url.blank?
      audit("system_table.refused", target_database, table_name, outcome: "refused",
            detail: "no such system database")
      raise UnknownDatabase, target_database
    end

    rows = fetch(url, table_name, [limit.to_i, MAX_LIMIT].min)

    audit("system_table.read", target_database, table_name, row_count: rows.length,
          detail: grant.reason)

    rows
  rescue PG::Error => e
    audit("system_table.read", target_database, table_name, outcome: "failed", detail: e.message)
    raise Error, e.message
  end

  private

  def fetch(url, table_name, limit)
    connection = PG.connect(url)
    begin
      # The table name is an identifier, not a value, so it cannot be bound.
      # It is quoted through the connection instead, and it only ever reaches
      # here after matching a grant row, so it is not free text either.
      quoted = connection.quote_ident(table_name)
      result = connection.exec_params("SELECT * FROM #{quoted} LIMIT $1", [limit])
      result.to_a
    ensure
      connection.close
    end
  end

  def audit(action, target_database, table_name, outcome: "allowed", row_count: nil, detail: nil)
    AuditEvent.record!(
      module_name: @registration.module_name,
      domain: @domain,
      action: action,
      subject: "#{target_database}.#{table_name}",
      outcome: outcome,
      row_count: row_count,
      detail: detail
    )
  end
end

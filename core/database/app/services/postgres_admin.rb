# frozen_string_literal: true

require "pg"

# Creates databases and roles on the module data cluster.
#
# The only code in the system that holds superuser credentials for that cluster.
# Everything above it deals in modules and domains; the SQL lives here so that
# swapping the cluster, or the engine it runs on, touches one file.
#
# Identifiers are always quoted through the connection rather than interpolated.
# A module name reaches this class from a manifest, and a manifest is written by
# somebody else.
class PostgresAdmin
  class Error < StandardError; end

  def initialize(url: ENV.fetch("MODULEDB_ADMIN_URL"))
    @url = url
  end

  def reachable?
    with_connection { |connection| connection.exec("SELECT 1") }
    true
  rescue StandardError
    false
  end

  def version
    with_connection { |connection| connection.exec("SHOW server_version").first.fetch("server_version") }
  end

  # Idempotent: an existing database and role are the state the caller wanted.
  def provision(database_name:, role_name:, password:)
    with_connection do |connection|
      harden(connection)
      create_role(connection, role_name, password)
      create_database(connection, database_name, role_name)
      lock_down(connection, database_name, role_name)
    end
    true
  rescue PG::Error => e
    raise Error, e.message
  end

  # Closes the door every fresh Postgres cluster leaves open.
  #
  # Revoking CONNECT per database is not enough on its own: `postgres` and
  # `template1` still admit PUBLIC, and from either of them a module role can
  # read pg_database and pg_roles and enumerate every other tenant. Isolating
  # the tenants while leaving the lobby unlocked is not isolation.
  #
  # Idempotent, and cheap enough to run on every provision rather than relying
  # on somebody having run a setup step once.
  def harden_cluster!
    with_connection { |connection| harden(connection) }
    true
  rescue PG::Error => e
    raise Error, e.message
  end

  def rotate_password(role_name:, password:)
    with_connection do |connection|
      connection.exec("ALTER ROLE #{quote_ident(connection, role_name)} " \
                      "WITH PASSWORD #{connection.escape_literal(password)}")
    end
    true
  rescue PG::Error => e
    raise Error, e.message
  end

  # Locks the role out without destroying anything. Removing a module should
  # not remove its data, so revoking its login is the strongest safe move.
  def revoke_login(role_name:)
    with_connection do |connection|
      connection.exec("ALTER ROLE #{quote_ident(connection, role_name)} WITH NOLOGIN")
    end
    true
  rescue PG::Error => e
    raise Error, e.message
  end

  def database_exists?(name)
    with_connection do |connection|
      result = connection.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [name])
      result.ntuples.positive?
    end
  end

  def role_exists?(name)
    with_connection do |connection|
      result = connection.exec_params("SELECT 1 FROM pg_roles WHERE rolname = $1", [name])
      result.ntuples.positive?
    end
  end

  # Sizes, for the Backoffice and for quota conversations later.
  def database_size(name)
    with_connection do |connection|
      result = connection.exec_params("SELECT pg_database_size($1) AS size", [name])
      result.first["size"].to_i
    end
  rescue PG::Error
    nil
  end

  private

  # PUBLIC keeps CONNECT on the databases a cluster ships with. A module role
  # that can reach `postgres` can read pg_database and pg_roles, which is every
  # other tenant's name and every database on the box.
  def harden(connection)
    %w[postgres template1].each do |database|
      connection.exec("REVOKE CONNECT ON DATABASE #{quote_ident(connection, database)} FROM PUBLIC")
    end
  end

  def create_role(connection, role_name, password)
    return if role_exists_in?(connection, role_name)

    connection.exec("CREATE ROLE #{quote_ident(connection, role_name)} LOGIN " \
                    "PASSWORD #{connection.escape_literal(password)}")
  end

  def create_database(connection, database_name, role_name)
    return if database_exists_in?(connection, database_name)

    # CREATE DATABASE cannot run inside a transaction block, which is why this
    # class talks to Postgres directly rather than through ActiveRecord.
    connection.exec("CREATE DATABASE #{quote_ident(connection, database_name)} " \
                    "OWNER #{quote_ident(connection, role_name)}")
  end

  # The default in Postgres is that every role can connect to every database.
  # Without this, isolation would be a naming convention.
  def lock_down(connection, database_name, role_name)
    connection.exec("REVOKE CONNECT ON DATABASE #{quote_ident(connection, database_name)} FROM PUBLIC")
    connection.exec("GRANT CONNECT ON DATABASE #{quote_ident(connection, database_name)} " \
                    "TO #{quote_ident(connection, role_name)}")
  end

  def role_exists_in?(connection, name)
    connection.exec_params("SELECT 1 FROM pg_roles WHERE rolname = $1", [name]).ntuples.positive?
  end

  def database_exists_in?(connection, name)
    connection.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [name]).ntuples.positive?
  end

  def quote_ident(connection, identifier)
    connection.quote_ident(identifier.to_s)
  end

  def with_connection
    connection = PG.connect(@url)
    begin
      yield connection
    ensure
      connection.close
    end
  rescue PG::ConnectionBad => e
    raise Error, "module data cluster unreachable: #{e.message}"
  end
end

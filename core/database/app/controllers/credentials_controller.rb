# frozen_string_literal: true

# Where a module collects the credentials for its own database.
#
# It then connects to Postgres directly. This service is not in the path of a
# module reading its own data, and should not be: a proxy in front of every
# query buys nothing that Postgres roles do not already give.
class CredentialsController < ApplicationController
  include ModuleAuthentication

  # GET /v1/credentials
  def show
    logical = params.fetch(:name, "primary")
    provisioned = current_module.provisioned_databases.find_by(domain: current_domain, logical_name: logical)

    unless provisioned&.ready?
      # Says what this module does have, not only what it asked for.
      #
      # It used to answer "no database provisioned for X on Y", which is true
      # and is also what a module with no databases at all would be told. A
      # module whose manifest declares `deliveries` and whose code asks for
      # `primary` gets exactly that message, and the forty minutes it took to
      # find that once is the reason for this line.
      available = current_module.provisioned_databases.where(domain: current_domain).pluck(:logical_name)

      detail = if available.empty?
                 "no database is provisioned for it on that domain at all"
               else
                 "it has: #{available.sort.join(', ')}"
               end

      return render json: {
        error: "#{current_module.module_name} has no database named #{logical.inspect} " \
               "on #{current_domain}; #{detail}",
        requested: logical,
        available: available
      }, status: :not_found
    end

    # Issuing credentials is itself an audited event. Somebody asking for them
    # at three in the morning is worth being able to see later.
    AuditEvent.record!(
      module_name: current_module.module_name,
      domain: current_domain,
      action: "credentials.issued",
      subject: provisioned.database_name,
      detail: "requested by the module"
    )

    render json: provisioned.connection_details
  end

  # GET /v1/databases
  def index
    databases = current_module.provisioned_databases.where(domain: current_domain).map do |provisioned|
      { logical_name: provisioned.logical_name, database: provisioned.database_name, state: provisioned.state }
    end

    render json: { databases: databases, domain: current_domain }
  end
end

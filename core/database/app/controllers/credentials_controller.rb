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
      return render json: {
        error: "no database provisioned for #{current_module.module_name} on #{current_domain}"
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

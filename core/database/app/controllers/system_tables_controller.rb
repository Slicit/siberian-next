# frozen_string_literal: true

# Reading a table in a database this module does not own.
#
# Granted table by table at install time, and every read lands in the audit
# trail, including the refusals.
class SystemTablesController < ApplicationController
  include ModuleAuthentication

  # GET /v1/system/:database/:table
  def show
    reader = SystemTableReader.new(current_module, domain: current_domain)
    rows = reader.read(params[:database], params[:table], limit: params.fetch(:limit, 100))

    render json: { database: params[:database], table: params[:table], rows: rows, count: rows.length }
  rescue SystemTableReader::NotGranted => e
    render json: { error: e.message }, status: :forbidden
  rescue SystemTableReader::UnknownDatabase => e
    render json: { error: "no system database named #{e.message}" }, status: :not_found
  rescue SystemTableReader::Error => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /v1/system
  #
  # What this module may read. A module that can see its own grants can explain
  # itself to a user, and cannot be surprised by a refusal.
  def index
    grants = current_module.table_grants.live.map do |grant|
      { database: grant.target_database, table: grant.table_name, access: grant.access, reason: grant.reason }
    end

    render json: { grants: grants }
  end
end

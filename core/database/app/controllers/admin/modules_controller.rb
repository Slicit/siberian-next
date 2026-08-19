# frozen_string_literal: true

# The Orchestrator's way in: register a module, provision its databases, record
# the table grants an operator approved.
#
# Behind the admin token. A module cannot grant itself access to anything, which
# is the entire point of approving grants at install time.
module Admin
  class ModulesController < ApplicationController
    before_action :authenticate_admin!

    # POST /admin/modules
    def create
      registration, token = ModuleRegistration.register!(
        module_name: params.require(:module_name),
        module_uuid: params.require(:module_uuid)
      )

      AuditEvent.record!(module_name: registration.module_name, action: "module.registered",
                         detail: "token issued")

      render json: { module_name: registration.module_name, token: token }, status: :created
    end

    # POST /admin/modules/:module_name/databases
    def provision
      registration = ModuleRegistration.find_by!(module_name: params[:module_name])
      provisioned = DatabaseProvisioner.new.call(
        registration,
        domain: params.require(:domain),
        logical_name: params.fetch(:logical_name, "primary")
      )

      render json: {
        module_name: registration.module_name,
        domain: provisioned.domain,
        database: provisioned.database_name,
        role: provisioned.role_name,
        state: provisioned.state
      }
    rescue PostgresAdmin::Error => e
      render json: { error: e.message }, status: :bad_gateway
    end

    # POST /admin/modules/:module_name/table_grants
    #
    # One call per approval, carrying the reason the operator saw. Storing the
    # reason matters: six months later the trail should say why somebody was
    # allowed to read a table, not merely that they were.
    def grant_tables
      registration = ModuleRegistration.find_by!(module_name: params[:module_name])
      target = params.require(:target_database)
      reason = params[:reason]

      grants = Array(params.require(:tables)).map do |table|
        grant = registration.table_grants.find_or_initialize_by(target_database: target, table_name: table)
        grant.assign_attributes(access: params.fetch(:access, "read"), reason: reason,
                                approved_at: Time.current, revoked_at: nil)
        grant.save!

        AuditEvent.record!(module_name: registration.module_name, action: "grant.approved",
                           subject: "#{target}.#{table}", detail: reason)
        grant
      end

      render json: { module_name: registration.module_name, grants: grants.map(&:to_s) }, status: :created
    end

    # POST /admin/modules/:module_name/rotate
    def rotate
      registration = ModuleRegistration.find_by!(module_name: params[:module_name])
      provisioned = registration.provisioned_databases.find_by!(
        domain: params.require(:domain),
        logical_name: params.fetch(:logical_name, "primary")
      )

      DatabaseProvisioner.new.rotate(provisioned)
      render json: { rotated: provisioned.database_name, at: provisioned.rotated_at }
    end

    # DELETE /admin/modules/:module_name
    #
    # Revokes the identity and locks the roles out. Nothing is dropped: a module
    # reinstalled to find its tables gone is a far worse surprise than a
    # database left behind.
    def destroy
      registration = ModuleRegistration.find_by!(module_name: params[:module_name])
      registration.update!(revoked_at: Time.current)
      registration.table_grants.live.update_all(revoked_at: Time.current)

      registration.provisioned_databases.ready.each do |provisioned|
        begin
          DatabaseProvisioner.new.suspend(provisioned)
        rescue PostgresAdmin::Error => e
          Rails.logger.warn("could not suspend #{provisioned.role_name}: #{e.message}")
        end
      end

      AuditEvent.record!(module_name: registration.module_name, action: "module.revoked",
                         detail: "grants withdrawn, roles locked out, data retained")

      head :no_content
    end

    private

    def authenticate_admin!
      expected = ENV.fetch("SIBERIAN_ADMIN_TOKEN", "orchestrator_dev_only")
      given = request.headers["Authorization"].to_s.delete_prefix("Bearer ").strip
      return if ActiveSupport::SecurityUtils.secure_compare(given, expected)

      render json: { error: "admin token required" }, status: :unauthorized
    end
  end
end

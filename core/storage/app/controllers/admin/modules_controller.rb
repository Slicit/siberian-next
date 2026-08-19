# frozen_string_literal: true

# The Orchestrator's way in. Registers a module and hands back the token that
# module will use for every later call.
#
# Guarded by a shared admin token rather than a module token, because a module
# registering itself would defeat the point of grants being approved by an
# operator first.
module Admin
  class ModulesController < ApplicationController
    before_action :authenticate_admin!

    # POST /admin/modules
    def create
      registration, token = ModuleRegistration.register!(
        module_name: params.require(:module_name),
        module_uuid: params.require(:module_uuid),
        spaces: params.fetch(:spaces, []),
        quota_mb: params.fetch(:quota_mb, 512).to_i,
        tmp_ttl_hours: params.fetch(:tmp_ttl_hours, 168).to_i
      )

      # The token is readable exactly once, here. After this only its digest
      # exists, so a leaked table is not a leaked identity.
      render json: {
        module_name: registration.module_name,
        spaces: registration.spaces,
        quota_mb: registration.quota_mb,
        token: token
      }, status: :created
    end

    # POST /admin/modules/:module_name/buckets
    def provision
      registration = ModuleRegistration.find_by!(module_name: params[:module_name])
      bucket = BucketProvisioner.new.call(registration, params.require(:domain))

      render json: { module_name: registration.module_name, domain: bucket.domain, bucket: bucket.name }
    rescue GarageAdmin::Error => e
      render json: { error: e.message }, status: :bad_gateway
    end

    # DELETE /admin/modules/:module_name
    def destroy
      registration = ModuleRegistration.find_by!(module_name: params[:module_name])
      registration.update!(revoked_at: Time.current)

      # Buckets survive. Revoking a module's identity is not the same as
      # destroying the files it wrote, and only an operator decides the second.
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

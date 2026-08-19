# frozen_string_literal: true

# Roles: bundles of permissions with a name.
#
# Editing one changes what everybody holding it can do, which is the point and
# also the danger, so the page says how many people that is before you save.
class RolesController < ApplicationController
  requires "core.roles.manage"

  def index
    directory = auth.roles || { "roles" => [], "catalogue" => [] }
    @roles = directory["roles"] || []
    @catalogue = Siberian::Permissions::CATALOGUE
  end

  def create
    result = auth.create_role(
      name: params[:name], description: params[:description],
      permissions: Array(params[:permissions]).reject(&:blank?)
    )

    if result && result["id"]
      redirect_to roles_path, notice: "#{result['name']} created."
    else
      redirect_to roles_path, alert: "Could not create it: #{Array(result && result['errors']).join(', ')}"
    end
  end

  def update
    auth.update_role(params[:id],
                     description: params[:description],
                     permissions: Array(params[:permissions]).reject(&:blank?))
    redirect_to roles_path, notice: "Saved. Everybody holding it re-resolves on their next request."
  end

  def destroy
    result = auth.delete_role(params[:id], force: params[:force] == "true")

    if result.nil?
      redirect_to roles_path, alert: "Could not remove it. It may still be held by somebody."
    else
      redirect_to roles_path, notice: "Role removed."
    end
  end
end

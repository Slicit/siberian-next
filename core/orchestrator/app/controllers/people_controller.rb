# frozen_string_literal: true

# People, and what each of them may do.
#
# Reading and changing are separate permissions on purpose: seeing who has
# access is a normal operator question, and changing it is not.
class PeopleController < ApplicationController
  requires "core.users.read"
  requires "core.users.write", only: %i[create update deactivate assign_role unassign_role grant revoke]

  def index
    directory = auth.users || { "users" => [], "roles" => [], "catalogue" => [] }
    @people = directory["users"] || []
    @roles = directory["roles"] || []
  end

  def show
    @person = auth.user(params[:id])
    return redirect_to people_path, alert: "No such person." if @person.nil?

    @roles = (auth.roles || {})["roles"] || []
    @catalogue = Siberian::Permissions::CATALOGUE
  end

  def create
    result = auth.create_user(
      email: params[:email], name: params[:name],
      password: params[:password], role_ids: Array(params[:role_ids]).reject(&:blank?)
    )

    if result && result["id"]
      redirect_to person_path(result["id"]), notice: "#{result['email']} added."
    else
      redirect_to people_path, alert: "Could not add that person: #{errors_from(result)}"
    end
  end

  def update
    result = auth.update_user(params[:id], name: params[:name], email: params[:email])
    redirect_to person_path(params[:id]), notice: result ? "Saved." : "Could not save."
  end

  def deactivate
    reactivating = params[:reactivate] == "true"
    auth.set_user_active(params[:id], reactivating)

    redirect_to person_path(params[:id]),
                notice: reactivating ? "Reactivated." : "Deactivated, and their sessions ended."
  end

  def assign_role
    auth.assign_role(params[:id], params.require(:role_id))
    redirect_to person_path(params[:id]), notice: "Role added."
  end

  def unassign_role
    auth.unassign_role(params[:id], params.require(:role_id))
    redirect_to person_path(params[:id]), notice: "Role removed."
  end

  def grant
    auth.grant(params[:id], params.require(:permission),
               effect: params.fetch(:effect, "allow"), reason: params[:reason])
    redirect_to person_path(params[:id]), notice: "Grant added."
  end

  def revoke
    auth.revoke(params[:id], params.require(:permission), effect: params.fetch(:effect, "allow"))
    redirect_to person_path(params[:id]), notice: "Grant removed."
  end

  private

  def errors_from(result)
    Array(result && result["errors"]).join(", ").presence || "unknown error"
  end
end

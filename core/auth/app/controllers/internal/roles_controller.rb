# frozen_string_literal: true

# Roles: bundles of permissions with a name.
#
# Editing one changes the answers for everybody holding it, which is exactly why
# they exist and exactly why every holder is invalidated on save.
module Internal
  class RolesController < ActionController::API
    include Siberian::ServiceAuthentication
    permit_services :orchestrator
    before_action :set_role, only: %i[update destroy]

    def index
      render json: {
        roles: Role.ordered.map { |role| serialize(role) },
        catalogue: Siberian::Permissions::CATALOGUE
      }
    end

    # POST /internal/roles/reconcile
    #
    # Called by the Orchestrator's reconciler. Adding a permission to the
    # catalogue is a code change; delivering it to the roles of an installation
    # that was seeded before it existed is this.
    def reconcile
      added = Role.reconcile_seeded!

      render json: {
        added: added,
        roles: Role.ordered.map { |role| serialize(role) }
      }
    end

    def create
      role = Role.new(role_params)

      if role.save
        render json: serialize(role), status: :created
      else
        render json: { errors: role.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      if @role.update(role_params)
        render json: serialize(@role.reload)
      else
        render json: { errors: @role.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      holders = @role.role_assignments.count

      # Deleting a role somebody holds silently takes their access away. Saying
      # so and refusing is better than doing it and hoping somebody notices.
      if holders.positive? && params[:force] != "true"
        return render json: {
          error: "#{@role.name} is held by #{holders} person(s). Pass force=true to remove it anyway."
        }, status: :conflict
      end

      @role.destroy!
      head :no_content
    end

    private

    def set_role
      @role = Role.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "no such role" }, status: :not_found
    end

    def role_params
      permitted = params.permit(:name, :description, permissions: [])
      permitted[:permissions] = Array(permitted[:permissions]).reject(&:blank?) if permitted.key?(:permissions)
      permitted
    end

    def serialize(role)
      {
        id: role.id,
        name: role.name,
        description: role.description,
        permissions: role.permission_list,
        seeded: role.seeded,
        member_count: role.role_assignments.count
      }
    end

  end
end

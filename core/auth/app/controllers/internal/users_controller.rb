# frozen_string_literal: true

# The user directory and everything that changes it.
#
# Behind the admin token, and called by the Backoffice and the Base App rather
# than by a browser. Both of them check the caller's own permission before
# calling: this endpoint trusts the service, the service checks the person.
module Internal
  class UsersController < ActionController::API
    include Siberian::ServiceAuthentication
    permit_services :orchestrator
    before_action :set_user, only: %i[show update destroy assign_role unassign_role grant revoke]

    def index
      users = User.ordered.includes(:roles).limit(500)

      render json: {
        users: users.map { |user| summary(user) },
        roles: Role.ordered.map { |role| role_summary(role) },
        catalogue: Siberian::Permissions::CATALOGUE
      }
    end

    def show
      render json: detail(@user)
    end

    def create
      user = User.new(user_params)
      user.password = params[:password].presence || SecureRandom.urlsafe_base64(18)

      if user.save
        Array(params[:role_ids]).each do |role_id|
          user.role_assignments.create(role_id: role_id)
        end
        render json: detail(user.reload), status: :created
      else
        render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      attributes = user_params
      attributes = attributes.merge(password: params[:password]) if params[:password].present?

      if @user.update(attributes)
        render json: detail(@user.reload)
      else
        render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # Deactivation, not deletion. A person who did things should still be
    # attached to them, and a deleted row makes an audit trail lie.
    def destroy
      if params[:reactivate] == "true"
        @user.reactivate!
      else
        @user.deactivate!
      end

      render json: detail(@user.reload)
    end

    def assign_role
      assignment = @user.role_assignments.find_or_initialize_by(role_id: params.require(:role_id))
      assignment.save!
      render json: detail(@user.reload)
    end

    def unassign_role
      @user.role_assignments.where(role_id: params.require(:role_id)).destroy_all
      render json: detail(@user.reload)
    end

    def grant
      grant = @user.permission_grants.find_or_initialize_by(
        permission: params.require(:permission),
        effect: params.fetch(:effect, "allow")
      )
      grant.reason = params[:reason]

      if grant.save
        render json: detail(@user.reload)
      else
        render json: { errors: grant.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def revoke
      @user.permission_grants.where(
        permission: params.require(:permission),
        effect: params.fetch(:effect, "allow")
      ).destroy_all

      render json: detail(@user.reload)
    end

    private

    def set_user
      @user = User.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "no such user" }, status: :not_found
    end

    def user_params
      params.permit(:email, :name).compact_blank
    end

    def summary(user)
      {
        id: user.id,
        email: user.email,
        name: user.display_name,
        active: user.active,
        roles: user.roles.map(&:name),
        last_seen_at: user.last_seen_at
      }
    end

    def detail(user)
      permissions = user.resolved_permissions

      summary(user).merge(
        role_ids: user.role_assignments.pluck(:role_id),
        grants: user.permission_grants.map { |grant| { permission: grant.permission, effect: grant.effect, reason: grant.reason } },
        effective_permissions: permissions.to_a,
        denied: permissions.denied,
        session_count: user.sessions.active.count
      )
    end

    def role_summary(role)
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

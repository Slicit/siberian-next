# frozen_string_literal: true

# The user directory, for core services that legitimately need one: the
# Backoffice listing operators, and the core.user.picker capability the Base
# App offers to modules.
#
# Behind the admin token. A module that wants a user list asks through a
# capability, not by reaching in here.
module Internal
  class UsersController < ActionController::API
    before_action :authenticate_admin!

    def index
      users = User.order(:email).limit(200)
      render json: { users: users.map(&:to_identity) }
    end

    def show
      user = User.find(params[:id])
      render json: user.to_identity
    rescue ActiveRecord::RecordNotFound
      render json: { error: "no such user" }, status: :not_found
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

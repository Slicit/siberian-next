# frozen_string_literal: true

# How an operator sees and manages the people using a domain's app.
#
# Internal, so it is reachable from the Backoffice and not from a phone. An app
# account can read and end its own sessions through `/-/auth/devices`; deciding
# that somebody may no longer sign in at all is an operator's call, and the two
# doors stay separate for the same reason the two account types do.
#
# Everything here is scoped to one domain, and the domain is a required
# parameter rather than an inferred one: a listing that quietly defaults to the
# wrong tenant is the worst bug this endpoint could have.
module Internal
  class AppUsersController < ActionController::API
    before_action :require_domain

    # GET /internal/app-users?domain=...
    def index
      accounts = AppUser.on(@domain).ordered

      render json: {
        domain: @domain,
        settings: AppSetting.for(@domain).to_h,
        users: accounts.map { |account| summary(account) }
      }
    end

    # POST /internal/app-users
    #
    # An operator creating an account directly, which is the only way in while
    # registration is closed.
    def create
      account = AppUser.new(
        domain: @domain,
        email: params[:email],
        name: params[:name],
        password: params[:password]
      )

      if account.save
        # The same link a self signed-up account gets. An operator vouching for
        # somebody does not make the address theirs, and an account that can
        # never be verified is permanently marked unverified through no fault
        # of the person using it.
        AppVerification.new.send_to(account, domain: @domain)
        render json: summary(account), status: :created
      else
        render json: { error: account.errors.full_messages.to_sentence },
               status: :unprocessable_entity
      end
    end

    # PATCH /internal/app-users/:id
    def update
      account = find_account
      return if performed?

      account.name = params[:name] if params.key?(:name)
      # Blank rather than absent, because a form posts every field and an empty
      # password box means "leave it alone" rather than "set it to nothing".
      account.password = params[:password] if params[:password].present?

      if account.save
        render json: summary(account)
      else
        render json: { error: account.errors.full_messages.to_sentence },
               status: :unprocessable_entity
      end
    end

    # POST /internal/app-users/:id/deactivate
    def deactivate
      account = find_account
      return if performed?

      account.deactivate!
      render json: summary(account)
    end

    # POST /internal/app-users/:id/reactivate
    def reactivate
      account = find_account
      return if performed?

      account.reactivate!
      render json: summary(account)
    end

    # DELETE /internal/app-users/:id/devices/:device_id
    #
    # One device, not the account. The account keeps working everywhere else,
    # which is what "this phone was lost" means.
    def revoke_device
      account = find_account
      return if performed?

      device = account.app_sessions.active.find_by(id: params[:device_id])
      return render json: { error: "no such device" }, status: :not_found if device.nil?

      device.revoke!
      render json: summary(account)
    end

    # PATCH /internal/app-settings
    def settings
      setting = AppSetting.for(@domain)
      setting.update!(registration_open: params[:registration_open].to_s == "true")

      render json: setting.to_h
    end

    private

    def require_domain
      @domain = params[:domain].to_s.strip.downcase
      return if @domain.present?

      render json: { error: "domain is required" }, status: :unprocessable_entity
    end

    def find_account
      account = AppUser.on(@domain).find_by(id: params[:id])
      render json: { error: "no such account on this domain" }, status: :not_found if account.nil?
      account
    end

    def summary(account)
      account.to_identity.merge(
        deactivated_at: account.deactivated_at,
        last_seen_at: account.last_seen_at,
        created_at: account.created_at,
        devices: account.app_sessions.active.recent.map(&:to_device)
      )
    end
  end
end

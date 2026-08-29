# frozen_string_literal: true

# The people a domain's app is for.
#
# Separate from People, which is the list of accounts that run the system. These
# are accounts that use one domain's product, they cannot reach this Backoffice,
# and the same address can belong to a different person on another domain. One
# list holding both kinds would make all three of those easy to forget.
#
# Managed under `core.mobile.manage` rather than `core.users.write`: this is the
# app's audience, and whoever configures the app is who decides who may sign in
# to it.
class AppUsersController < ApplicationController
  requires "core.modules.read"
  requires "core.mobile.manage", only: %i[create registration set_active revoke_device set_password]

  def index
    @domains = Domain.ordered
  end

  def show
    @domain = Domain.find_by(id: params[:id])
    return redirect_to app_users_path, alert: "No such domain." if @domain.nil?

    @breadcrumb_leaf = @domain.hostname
    report = auth.app_users(@domain.hostname) || {}
    @accounts = Array(report["users"])
    @settings = report["settings"] || { "registration_open" => false }
  end

  def create
    domain = Domain.find_by(id: params[:id])
    return redirect_to app_users_path, alert: "No such domain." if domain.nil?

    result = auth.create_app_user(domain.hostname,
                                  email: params[:email], name: params[:name],
                                  password: params[:password])

    redirect_to domain_app_users_path(domain),
                **flash_for(result, "#{params[:email]} can now sign in to the app.")
  end

  # Whether a stranger may create an account on this domain.
  #
  # Worth an explicit switch rather than a setting buried elsewhere: turning it
  # on means anyone who can reach the domain can create an account on it, and
  # that is a decision somebody should make on purpose.
  def registration
    domain = Domain.find_by(id: params[:id])
    return redirect_to app_users_path, alert: "No such domain." if domain.nil?

    open = params[:registration_open] == "true"
    result = auth.set_app_registration(domain.hostname, open)

    redirect_to domain_app_users_path(domain),
                **flash_for(result, open ? "Anyone can now sign up on this domain." : "Sign-up closed.")
  end

  # An operator setting a password for somebody who cannot receive the email.
  #
  # The last resort rather than the normal path: the reset link exists so that
  # nobody has to be told their password by another person. It is here because
  # a mail transport that is down would otherwise mean nobody can get back in
  # at all.
  def set_password
    domain = Domain.find_by(id: params[:id])
    return redirect_to app_users_path, alert: "No such domain." if domain.nil?

    result = auth.update_app_user(domain.hostname, params[:account_id], password: params[:password])

    redirect_to domain_app_users_path(domain),
                **flash_for(result, "Password set. Tell them in person, not by email.")
  end

  def set_active
    domain = Domain.find_by(id: params[:id])
    return redirect_to app_users_path, alert: "No such domain." if domain.nil?

    active = params[:active] == "true"
    result = auth.set_app_user_active(domain.hostname, params[:account_id], active)

    redirect_to domain_app_users_path(domain),
                **flash_for(result, active ? "Account restored." : "Account deactivated on every device.")
  end

  def revoke_device
    domain = Domain.find_by(id: params[:id])
    return redirect_to app_users_path, alert: "No such domain." if domain.nil?

    result = auth.revoke_app_device(domain.hostname, params[:account_id], params[:device_id])

    redirect_to domain_app_users_path(domain),
                **flash_for(result, "That device is signed out. The others are not.")
  end

  private

  def flash_for(result, notice)
    return { notice: notice } if result

    { alert: "Auth would not do that." }
  end
end

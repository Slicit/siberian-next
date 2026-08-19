# frozen_string_literal: true

class DomainsController < ApplicationController
  def index
    @domains = Domain.ordered
    @domain = Domain.new
  end

  def create
    @domain = Domain.new(domain_params)

    if @domain.save
      republish_routes
      redirect_to domains_path, notice: "#{@domain.hostname} added and routes republished."
    else
      @domains = Domain.ordered
      render :index, status: :unprocessable_entity
    end
  end

  def update
    domain = Domain.find(params[:id])
    domain.update!(primary: true)
    redirect_to domains_path, notice: "#{domain.hostname} is now the primary domain."
  end

  def destroy
    domain = Domain.find(params[:id])

    if Domain.count == 1
      return redirect_to domains_path, alert: "The last domain cannot be removed."
    end

    hostname = domain.hostname
    domain.destroy!
    republish_routes
    redirect_to domains_path, notice: "#{hostname} removed."
  end

  private

  def domain_params
    params.require(:domain).permit(:hostname, :label, :primary)
  end

  # Every installed module needs a server block for the new domain, or the
  # domain exists in the database and nowhere else.
  def republish_routes
    router = RouterConfig.new
    domains = Domain.ordered.to_a
    InstalledModule.live.find_each { |installed| router.write(installed, domains) }
    router.reload
  rescue StandardError => e
    flash[:alert] = "Domain saved, but the router did not reload: #{e.message}"
  end
end

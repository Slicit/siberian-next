# frozen_string_literal: true

# The phone app for each domain: what it is, what it may do natively, and what
# is in the build queue.
#
# Reading is part of running the system. Switching on a native capability is
# not: each one is something the app can then do to somebody, so it has a
# permission of its own for the same reason storage quotas do.
class MobileController < ApplicationController
  requires "core.modules.read"
  requires "core.mobile.manage", only: %i[save update_capability build cancel]

  def index
    @domains = Domain.ordered
    @report = mobile.apps
    @apps = Array(@report && @report["apps"]).index_by { |app| app["domain"] }
    @catalogue = Array(@report && @report["catalogue"])
    @queue = mobile.builds
  end

  def show
    @domain = Domain.find_by(id: params[:id])
    return redirect_to mobile_path, alert: "No such domain." if @domain.nil?

    @app = mobile.app(@domain.hostname)
    @app = nil unless @app && @app["ok"]
    @catalogue = Array(mobile.apps&.[]("catalogue"))
    @builds = Array(mobile.builds(domain: @domain.hostname)&.[]("builds"))
  end

  # One app per domain, so this creates or updates rather than asking an
  # operator which they meant.
  def save
    domain = Domain.find_by(id: params[:id])
    return redirect_to mobile_path, alert: "No such domain." if domain.nil?

    result = mobile.save_app(domain.hostname, {
      name: params[:name],
      bundle_identifier: params[:bundle_identifier],
      version: params[:version],
      primary_color: params[:primary_color]
    })

    redirect_to mobile_app_path(domain), notice: notice_for(result, "App saved.")
  end

  def update_capability
    domain = Domain.find_by(id: params[:id])
    return redirect_to mobile_path, alert: "No such domain." if domain.nil?

    result = mobile.set_capability(domain.hostname, params[:capability], {
      enabled: params[:enabled] != "false",
      settings: params[:settings]&.permit!&.to_h || {}
    })

    redirect_to mobile_app_path(domain),
                notice: notice_for(result, "#{params[:capability].humanize} updated.")
  end

  # Queued, not built. One builder is shared by every domain, so asking for a
  # build is asking to be next, and the page says so rather than appearing to
  # hang.
  def build
    domain = Domain.find_by(id: params[:id])
    return redirect_to mobile_path, alert: "No such domain." if domain.nil?

    result = mobile.queue_build(domain: domain.hostname,
                                platform: params[:platform].presence || "android",
                                requested_by: current_user&.email)

    if result && result["ok"]
      place = result["position"] ? ", number #{result['position']} in line" : ""
      redirect_to mobile_app_path(domain), notice: "Build queued#{place}."
    else
      redirect_to mobile_app_path(domain), alert: refusal(result)
    end
  end

  def cancel
    domain = Domain.find_by(id: params[:id])
    return redirect_to mobile_path, alert: "No such domain." if domain.nil?

    result = mobile.cancel_build(params[:build_id])
    redirect_to mobile_app_path(domain), notice: notice_for(result, "Build cancelled.")
  end

  private

  def mobile
    @mobile ||= Siberian::MobileClient.new(logger: Rails.logger)
  end

  def notice_for(result, success)
    result && result["ok"] ? success : refusal(result)
  end

  # The service answers a refusal with what was wrong. Passing that through is
  # the difference between "could not save" and "purchases has no RevenueCat
  # key, and cannot work without one".
  def refusal(result)
    return "The Mobile service did not answer." if result.nil?

    detail = Array(result["misconfigured"]).map do |entry|
      "#{entry['capability']} needs #{Array(entry['missing']).join(' and ')}"
    end

    [result["error"], Array(result["errors"]).to_sentence.presence, detail.to_sentence.presence]
      .compact.reject(&:empty?).join(": ").presence || "That did not work."
  end
end

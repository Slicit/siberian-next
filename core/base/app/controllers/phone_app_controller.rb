# frozen_string_literal: true

# The phone app for this domain, configured from the product side.
#
# The Backoffice sees every domain because an operator runs the system. This
# page sees one, because whoever is here is inside a domain and that is the only
# app they have any business configuring. The controller never passes a domain
# it was given: it passes the one the Router put on the request.
class PhoneAppController < ApplicationController
  # The preview serves the exported app's own JavaScript, and Rails refuses to
  # send a JavaScript response to a request it cannot prove came from here: the
  # rule exists to stop another site pulling a signed-in page in with a script
  # tag and reading it. What comes back here is a build artifact rather than
  # anything about the person asking, it is a GET that changes nothing, and the
  # domain is the Router's rather than the caller's, so there is nothing for that
  # rule to protect. Signing in and holding core.mobile.manage is still required.
  skip_forgery_protection only: :preview

  before_action :require_permission!

  def show
    @breadcrumb_section = "Phone app"
    load_app
  end

  # A description in, a proposal out. Nothing is applied here, which is why this
  # is a separate action from the one that applies it: what a person accepts is
  # exactly what they were shown.
  def suggest
    @breadcrumb_section = "Phone app"
    @description = params[:description].to_s

    result = mobile.suggest(current_domain, @description)
    load_app

    if result.nil?
      flash.now[:alert] = "The assistant did not answer."
    elsif !result["ok"]
      flash.now[:alert] = result["error"].presence || "The assistant could not answer that."
    else
      @proposal = result["proposal"]
    end

    render :show
  end

  # Applies exactly what came back in the form, which is exactly what was on
  # screen. A capability the person unticked is not in the parameters at all.
  def apply
    saved = mobile.save_app(current_domain, {
      name: params[:name],
      bundle_identifier: params[:bundle_identifier],
      primary_color: params[:primary_color].presence
    })

    accepted = Array(params[:capabilities]).map(&:to_s)
    accepted.each { |capability| mobile.set_capability(current_domain, capability, { enabled: true }) }

    notice = if saved && saved["ok"]
               ["Saved.", accepted.any? ? "Switched on #{accepted.to_sentence}." : nil].compact.join(" ")
             else
               nil
             end

    if notice
      redirect_to phone_app_path, notice: notice
    else
      redirect_to phone_app_path, alert: "That did not save."
    end
  end

  def update_capability
    result = mobile.set_capability(current_domain, params[:capability],
                                   { enabled: params[:enabled] != "false" })

    redirect_to phone_app_path, notice: describe(result, "Updated.")
  end

  # Same two uploads as the Backoffice, on the domain this page is already
  # scoped to. Which one is decided by the field the form used, never by
  # sniffing the file.
  def upload_splash
    result = if params[:animation].present?
               mobile.upload_splash_animation(current_domain, params[:animation].read,
                                              duration_ms: params[:duration_ms])
             elsif params[:image].present?
               mobile.upload_splash(current_domain, params[:image].read, background: params[:background])
             end

    return redirect_to phone_app_path, alert: "Choose a file first." if result.nil? && params[:image].blank? && params[:animation].blank?

    if result && result["ok"]
      redirect_to phone_app_path, notice: ["Splash saved.", Array(result["warnings"]).join(" ")].join(" ").strip
    else
      redirect_to phone_app_path, alert: describe(result, nil)
    end
  end

  def remove_splash
    result = mobile.remove_splash(current_domain, kind: params[:kind].presence || "image")
    redirect_to phone_app_path, notice: describe(result, "Splash removed.")
  end

  def build
    result = mobile.queue_build(domain: current_domain,
                                platform: params[:platform].presence || "android",
                                requested_by: current_user&.email)

    if result && result["ok"]
      place = result["position"] ? ", number #{result['position']} in line" : ""
      redirect_to phone_app_path, notice: "Build queued#{place}."
    else
      redirect_to phone_app_path, alert: describe(result, nil)
    end
  end

  # The exported web build, proxied from the Mobile service. The domain is the
  # one the Router put on this request, so an app owner cannot fetch another
  # domain's export by asking for it.
  def preview
    found = mobile.preview(current_domain, params[:path].presence || "index.html")
    return head :not_found if found.nil?

    body, content_type = found
    send_data body, type: content_type.presence || "application/octet-stream", disposition: "inline"
  end

  private

  def mobile
    @mobile ||= Siberian::MobileClient.new(logger: Rails.logger)
  end

  def load_app
    report = mobile.app(current_domain)
    @app = report && report["ok"] ? report : nil
    @catalogue = Array(mobile.apps&.[]("catalogue"))

    queue = mobile.builds(domain: current_domain)

    # Told apart deliberately. "Nothing built yet" is a true and useful thing to
    # say when the queue is empty, and a lie when the answer never arrived. That
    # is the shape of failure that hides longest here, because a page that says
    # nothing happened looks exactly like a page where nothing happened, and
    # this section spent its whole life so far saying it to a refused request.
    @builds_unavailable = queue.nil? || !queue["ok"]
    @builds = Array(queue && queue["builds"])
    @queued = queue && queue["queued"].to_i
    @building = queue && queue["building"].to_i

    # What the preview iframe points at. The most recent web build that
    # finished, because a queued one has nothing to show and a failed one would
    # show the last good export while claiming to be current.
    @preview_build = @builds.find do |build|
      build["platform"] == "web" && build["state"] == "succeeded"
    end
    @preview_pending = @builds.any? do |build|
      build["platform"] == "web" && %w[queued building].include?(build["state"])
    end
  end

  # Configuring the app is not using the product. Somebody who can open the
  # modules here still cannot decide what the app may do to a phone.
  def require_permission!
    return if allow?("core.mobile.manage")

    render "shared/no_access", status: :forbidden
  end

  def describe(result, success)
    return "The Mobile service did not answer." if result.nil?
    return success if result["ok"] && success

    detail = Array(result["misconfigured"]).map do |entry|
      "#{entry['capability']} needs #{Array(entry['missing']).join(' and ')}"
    end

    [result["error"], detail.to_sentence.presence].compact.reject(&:empty?).join(": ").presence ||
      "That did not work."
  end
end

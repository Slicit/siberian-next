# frozen_string_literal: true

# Everything the builder needs to produce one app, resolved once.
#
# Resolved here rather than in the builder because every question it answers is
# a question about configuration, and configuration lives on this side. The
# builder receives an answer, not a database: it runs third-party module code,
# so the less it can ask, the better.
class BuildPlan
  def initialize(build)
    @build = build
    @app = build.mobile_app
  end

  # `secrets: false` is what gets stored on the build row. A capability's keys
  # are a credential, not a record of what was configured, and a credential kept
  # forever on a row nobody looks at again is a credential nobody is watching.
  def to_h(secrets: true)
    @secrets = secrets
    enabled = @app.enabled_capabilities

    {
      build_id: @build.id,
      platform: @build.platform,
      domain: @build.domain,
      app: {
        name: @app.name,
        bundle_identifier: @app.bundle_identifier,
        version: @app.version,
        # The number the store sees. Incremented on success, so a failed build
        # does not burn one and two artifacts can never share one.
        build_number: @app.build_number + 1,
        primary_color: @app.primary_color,
        icon_path: @app.icon_path
      },
      # What it shows before it has drawn anything. The bytes are not here: the
      # builder asks for them by kind when it claims, because a plan is a thing
      # that gets stored and an image is not.
      splash: {
        background: @app.splash_background.presence || @app.primary_color.presence || "#ffffff",
        image: @app.splash_image?,
        animation: @app.splash_animation? && @build.platform == Build::ANDROID,
        animation_duration_ms: @app.clamped_animation_duration
      },
      # Where the app talks to the core. The app has no origins, so every module
      # call is namespaced by path and the Router decides which module a path
      # segment means. Nothing here is chosen by the module.
      api: {
        base_url: "https://#{@build.domain}",
        module_prefix: "/m/"
      },
      capabilities: enabled.filter_map { |id| capability_entry(id) },
      modules: ModuleRegistration.live.ordered.map { |registration| module_entry(registration, enabled) }
    }
  end

  private

  def capability_entry(id)
    definition = Siberian::MobileCapabilities.find(id)
    return nil if definition.nil?

    row = @app.app_capabilities.find_by(capability: id)

    {
      id: definition[:id],
      package: definition[:package],
      # Apple rejects a build that asks for a permission without a sentence
      # explaining it, so the sentence travels with the capability rather than
      # being remembered at packaging time.
      usage: definition[:usage],
      settings: @secrets ? (row&.settings || {}) : {}
    }
  end

  def module_entry(registration, enabled)
    contribution = registration.contribution_for(enabled)

    {
      name: registration.module_name,
      kind: contribution[:kind],
      reason: contribution[:reason],
      screens: contribution[:screens] || [],
      entry: registration.native_entry,
      # The same UI the Base App frames. A module that ships nothing native gets
      # this, and so does one whose requirement an operator did not approve.
      web_url: "https://#{registration.origin.presence || registration.module_name}.apps.#{@build.domain}",
      api_base: "/m/#{registration.module_name}/"
    }
  end
end

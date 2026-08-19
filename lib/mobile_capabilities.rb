# frozen_string_literal: true

module Siberian
  # The native capabilities an app can be built with.
  #
  # A fixed catalogue rather than an open field, for the same reason permissions
  # are a catalogue: each of these is a package that has to be in the build, a
  # config plugin that has to be applied, and in several cases a sentence Apple
  # will show a person before they are asked to allow it. None of that can be
  # supplied by a manifest at install time.
  #
  # A module may require one. An operator decides whether it is on. A capability
  # a module requires and an operator has not enabled leaves that module's
  # native screen switched off, which is what an unmatched capability does
  # everywhere else in this system.
  module MobileCapabilities
    # `prompts` is whether the operating system stops somebody and asks. That is
    # not the same as asking a lot: in-app purchases are a serious capability
    # and show no permission dialog, while the network state is a mild one that
    # also shows none. Only a capability that prompts needs a `usage` string,
    # and Apple rejects a build that prompts without one.
    #
    # `usage` is that string.
    #
    # `settings` are the values an operator has to supply for the capability to
    # work at all. A capability with settings and no values is not enabled, it
    # is half configured, and the difference has to be visible.
    CATALOGUE = [
      {
        id: "location",
        package: "expo-location",
        label: "Location and GPS",
        summary: "Maps, geofencing, delivery tracking, local weather.",
        usage: "Shows you what is nearby and keeps deliveries accurate.",
        prompts: true,
        severity: :high,
        settings: []
      },
      {
        id: "biometric_auth",
        package: "expo-local-authentication",
        label: "Biometric sign in",
        summary: "Face ID, Touch ID, and fingerprint, to protect the app itself.",
        usage: "Unlocks the app without typing your password.",
        prompts: true,
        severity: :medium,
        settings: []
      },
      {
        id: "secure_storage",
        package: "expo-secure-store",
        label: "Secure storage",
        summary: "Session tokens and encryption keys in the Keychain or Keystore.",
        usage: nil,
        severity: :low,
        settings: []
      },
      {
        id: "haptics",
        package: "expo-haptics",
        label: "Haptics",
        summary: "Tactile feedback on presses, errors, and switches.",
        usage: nil,
        severity: :low,
        settings: []
      },
      {
        id: "file_system",
        package: "expo-file-system",
        label: "File system",
        summary: "Downloading documents, caching assets, saving data for offline use.",
        usage: nil,
        severity: :low,
        settings: []
      },
      {
        id: "device_info",
        package: "expo-device",
        label: "Device information",
        summary: "App version, OS build, and phone model, for support and diagnostics.",
        usage: nil,
        severity: :low,
        settings: []
      },
      {
        id: "app_tracking",
        package: "expo-tracking-transparency",
        label: "App tracking (iOS)",
        summary: "Asks for the iOS advertising identifier, for analytics and advertising.",
        usage: "Lets us measure which campaigns brought you here.",
        prompts: true,
        # The only capability here whose whole purpose is to follow somebody
        # between apps. An operator should have to mean it.
        severity: :high,
        settings: []
      },
      {
        id: "purchases",
        package: "react-native-purchases",
        label: "In-app purchases",
        summary: "Subscriptions, paywalls, and one-off purchases, through RevenueCat.",
        usage: nil,
        severity: :high,
        settings: [
          { key: "revenuecat_ios_key", label: "RevenueCat iOS public key", secret: true },
          { key: "revenuecat_android_key", label: "RevenueCat Android public key", secret: true }
        ]
      },
      {
        id: "web_browser",
        package: "expo-web-browser",
        label: "In-app browser",
        summary: "Opens OAuth flows in the system browser rather than a WebView, which is what Google and Apple require.",
        usage: nil,
        severity: :low,
        settings: []
      },
      {
        id: "push_notifications",
        package: "expo-notifications",
        label: "Push notifications",
        summary: "Sending a message to somebody when the app is closed, and the badge on the icon.",
        usage: "Lets us tell you when something needs you, without you having to look.",
        prompts: true,
        # An app that can interrupt somebody is asking for something different
        # from an app that can read the network state.
        severity: :high,
        settings: [
          { key: "expo_access_token", label: "Expo access token", secret: true, optional: true }
        ]
      },
      {
        id: "network_state",
        package: "expo-network",
        label: "Network state",
        summary: "Detecting offline mode and connection changes.",
        usage: nil,
        severity: :low,
        settings: []
      }
    ].freeze

    IDS = CATALOGUE.map { |capability| capability[:id] }.freeze

    def self.find(id)
      CATALOGUE.find { |capability| capability[:id] == id.to_s }
    end

    def self.known?(id) = IDS.include?(id.to_s)

    def self.unknown(ids) = Array(ids).map(&:to_s) - IDS

    # Everything the build needs installed for a set of enabled capabilities.
    def self.packages_for(ids)
      Array(ids).filter_map { |id| find(id)&.fetch(:package) }.uniq
    end

    # The settings that have to be filled in before a capability does anything.
    def self.required_settings(id)
      Array(find(id)&.fetch(:settings)).reject { |setting| setting[:optional] }
    end
  end
end

# frozen_string_literal: true

module Siberian
  # The palettes a phone app can be built in.
  #
  # One list, read by three things that would otherwise each invent their own:
  # the builder bakes it into the app, the Backoffice offers it as a choice, and
  # a module rendering inside a WebView is handed it so an embedded page and the
  # app around it are not two different products.
  #
  # That last one is the reason this is here rather than in the builder. A
  # module's web face is HTML rendered by the module, and it has no idea which
  # app is framing it unless something tells it. The colours travel with the
  # request and the module turns them into CSS variables, which is the shape its
  # stylesheet already uses.
  #
  # The keys are the contract. A theme is referenced by key everywhere, so
  # renaming one breaks an app that was built against it, and the values may be
  # tuned freely.
  module MobileThemes
    # Every theme carries the same keys, so a screen written against one works
    # in all of them and adding a theme is a palette rather than a code change.
    #
    #   background      the page behind everything
    #   surface         a card, a field, a raised row
    #   text            body text on background or surface
    #   muted           secondary text, metadata, placeholders
    #   line            borders and separators
    #   accent          the one colour that means "this is the action"
    #   onAccent        text drawn on top of accent
    #   danger          destructive actions and errors
    #   dangerSurface   the quiet background behind an error message
    #   scheme          light or dark, so a WebView can set color-scheme and a
    #                   native input can pick the right keyboard
    THEMES = {
      "daylight" => {
        name: "Daylight",
        description: "Clean and bright, with a confident blue. The default.",
        scheme: "light",
        background: "#f7f8fa",
        surface: "#ffffff",
        text: "#111827",
        muted: "#6b7280",
        line: "#e5e7eb",
        accent: "#2563eb",
        onAccent: "#ffffff",
        danger: "#b3261e",
        dangerSurface: "#fee2e2"
      },
      "midnight" => {
        name: "Midnight",
        description: "Dark, low glare, with a violet accent. For evening use.",
        scheme: "dark",
        background: "#0f1117",
        surface: "#181b23",
        text: "#e8ecf1",
        muted: "#9aa4b1",
        line: "#2a313a",
        accent: "#8b7bf7",
        onAccent: "#0f1117",
        danger: "#ef6b62",
        dangerSurface: "#2c1a1a"
      },
      "meadow" => {
        name: "Meadow",
        description: "Warm and soft, with a green accent. Easy on long reading.",
        scheme: "light",
        background: "#fbfaf6",
        surface: "#ffffff",
        text: "#1f2421",
        muted: "#6b7568",
        line: "#e4e6df",
        accent: "#2f855a",
        onAccent: "#ffffff",
        danger: "#a63d2f",
        dangerSurface: "#fdecea"
      }
    }.freeze

    DEFAULT = "daylight"

    def self.keys = THEMES.keys

    def self.exists?(key) = THEMES.key?(key.to_s)

    # The palette for a key, falling back rather than raising.
    #
    # An app built against a theme that was later removed should render in the
    # default rather than fail to build: a missing colour is a worse outcome
    # than an unexpected one, and the operator can see which theme is set.
    def self.fetch(key)
      THEMES.fetch(key.to_s, THEMES.fetch(DEFAULT))
    end

    # Everything, for a picker and for the app, which carries all of them so a
    # preview can switch without rebuilding.
    def self.all = THEMES

    # The colours only, without the prose. What travels to an app or a module.
    def self.palette(key)
      fetch(key).reject { |field, _| %i[name description].include?(field) }
    end

    # A theme as query parameters, for a module rendering inside a WebView.
    #
    # Sent as values rather than as a name so a module never has to carry a copy
    # of this list, and so a theme tuned here reaches an already-installed
    # module without changing it.
    def self.query_parameters(key)
      palette(key).transform_keys { |field| "theme_#{field}" }.merge("theme" => key.to_s)
    end
  end
end

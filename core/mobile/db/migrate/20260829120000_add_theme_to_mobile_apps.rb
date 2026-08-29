# frozen_string_literal: true

# Which palette an app is built in.
#
# A string rather than a set of colour columns: the palettes live in
# lib/mobile_themes.rb, where the builder, the Backoffice and a module inside a
# WebView all read the same one. Storing the colours here would mean an app
# built last month keeps last month's blue after the theme is tuned, which is
# the opposite of what a theme is for.
class AddThemeToMobileApps < ActiveRecord::Migration[8.1]
  def change
    add_column :mobile_apps, :theme, :string, null: false, default: "daylight"
  end
end

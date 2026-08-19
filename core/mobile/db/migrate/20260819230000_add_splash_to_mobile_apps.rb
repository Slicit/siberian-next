# frozen_string_literal: true

# What the app shows before it has drawn anything.
#
# Two independent things, because they answer to different systems. Every
# platform can show a still image. Only Android can animate one, and only as an
# AnimatedVectorDrawable through the platform splash screen API, which is a
# different file in a different place with a duration attached.
class AddSplashToMobileApps < ActiveRecord::Migration[8.1]
  def change
    change_table :mobile_apps, bulk: true do |t|
      # Paths in Storage, not the images. The Mobile service holds the one
      # credential that reaches them, and hands the bytes to the builder when it
      # claims a build.
      t.string :splash_image_path
      t.string :splash_background

      t.string :splash_animation_path
      # Android stops the animation at one second whatever this says, so the
      # value is clamped rather than trusted.
      t.integer :splash_animation_duration_ms, null: false, default: 1000
    end
  end
end

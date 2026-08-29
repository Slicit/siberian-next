# frozen_string_literal: true

# Whether the app should follow the light or dark setting on the phone it is
# running on.
#
# On by default, including for apps that already exist, and that is a behaviour
# change worth being deliberate about.
#
# The reasoning: a theme here is a palette rather than a light-or-dark decision.
# An operator who chose Meadow gets Meadow on every phone set to light, which is
# most of them, and only a phone that has asked for dark is shown something
# else. The alternative is showing a light app to somebody who set their phone
# to dark at eleven at night, which is the complaint this exists to answer.
#
# An operator who wants their palette regardless can turn it off, and the page
# says which it is doing rather than leaving it to be discovered.
class AddFollowDeviceSchemeToMobileApps < ActiveRecord::Migration[8.1]
  def change
    add_column :mobile_apps, :follow_device_scheme, :boolean, null: false, default: true
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "lib/mobile_themes"

# The palettes a phone app can be built in.
#
# Three things read this list: the builder bakes it into an app, the Backoffice
# offers it as a choice, and a module inside a WebView is handed it. So the
# tests are mostly about the shape being the same for all of them, because a
# theme missing a colour is a screen missing a colour.
class MobileThemesTest < Minitest::Test
  def themes = Siberian::MobileThemes

  def test_there_are_three_and_the_default_is_one_of_them
    assert_equal 3, themes.all.length
    assert_includes themes.keys, themes::DEFAULT
  end

  # A screen is written against these names once and rendered in every theme, so
  # a palette missing one renders that element in nothing.
  def test_every_theme_carries_every_field
    expected = themes.fetch(themes::DEFAULT).keys.sort

    themes.all.each do |key, palette|
      assert_equal expected, palette.keys.sort, "#{key} does not carry the same fields"
    end
  end

  def test_every_theme_says_whether_it_is_light_or_dark
    themes.all.each do |key, palette|
      assert_includes %w[light dark], palette[:scheme], "#{key} has no usable scheme"
    end
  end

  # Contrast is the difference between a theme and a colour scheme somebody
  # cannot read. This is a floor rather than a full check: text on background
  # must not be nearly the same colour.
  def test_text_is_not_the_same_colour_as_the_background
    themes.all.each do |key, palette|
      assert_operator distance(palette[:text], palette[:background]), :>, 120,
                      "#{key} has text too close to its background to read"
    end
  end

  def test_accent_stands_out_from_the_surface_it_sits_on
    themes.all.each do |key, palette|
      assert_operator distance(palette[:accent], palette[:surface]), :>, 60,
                      "#{key} has an accent that disappears into its surface"
    end
  end

  # A label drawn on an accent-coloured button.
  def test_text_on_the_accent_is_readable
    themes.all.each do |key, palette|
      assert_operator distance(palette[:onAccent], palette[:accent]), :>, 120,
                      "#{key} draws its button label in nearly the button colour"
    end
  end

  def test_every_colour_is_a_hex_value
    themes.all.each do |key, palette|
      palette.each do |field, value|
        next if %i[name description scheme].include?(field)

        assert_match(/\A#[0-9a-f]{6}\z/i, value, "#{key}.#{field} is not a hex colour")
      end
    end
  end

  # An app built against a theme that was later removed should render in the
  # default rather than fail: a missing colour is worse than an unexpected one.
  def test_an_unknown_theme_falls_back_rather_than_raising
    assert_equal themes.fetch(themes::DEFAULT), themes.fetch("no-such-theme")
    assert_equal themes.fetch(themes::DEFAULT), themes.fetch(nil)
  end

  # What travels to an app or a module is colour, not prose.
  def test_the_palette_carries_no_prose
    palette = themes.palette("midnight")

    refute palette.key?(:name)
    refute palette.key?(:description)
    assert palette.key?(:accent)
  end

  def test_query_parameters_are_prefixed_and_name_the_theme
    parameters = themes.query_parameters("meadow")

    assert_equal "meadow", parameters["theme"]
    assert_equal themes.palette("meadow")[:accent], parameters["theme_accent"]
    refute parameters.key?("theme_name"), "prose does not travel"
  end


  # Following the phone's light or dark setting. A theme is a palette rather
  # than a light-or-dark decision, so the operator's choice has to survive
  # whenever it can: that is what makes this something they can leave on.
  def test_a_matching_theme_is_kept_rather_than_replaced
    assert_equal "meadow", themes.for_scheme("light", preferred: "meadow")
    assert_equal "daylight", themes.for_scheme("light", preferred: "daylight")
    assert_equal "midnight", themes.for_scheme("dark", preferred: "midnight")
  end

  def test_a_phone_asking_for_dark_gets_a_dark_theme
    themes.keys.each do |key|
      chosen = themes.for_scheme("dark", preferred: key)

      assert_equal "dark", themes.fetch(chosen)[:scheme],
                   "#{key} on a dark phone resolved to #{chosen}, which is not dark"
    end
  end

  def test_a_phone_asking_for_light_gets_a_light_theme
    themes.keys.each do |key|
      chosen = themes.for_scheme("light", preferred: key)

      assert_equal "light", themes.fetch(chosen)[:scheme],
                   "#{key} on a light phone resolved to #{chosen}, which is not light"
    end
  end

  # Anything that is not the word dark is light, including nil, because a device
  # that has not said is not a device asking for dark.
  def test_an_unknown_scheme_is_treated_as_light
    [nil, "", "sepia"].each do |scheme|
      assert_equal "light", themes.fetch(themes.for_scheme(scheme, preferred: "midnight"))[:scheme]
    end
  end
  private

  # Straight line distance in RGB. Crude, and enough to catch a palette where
  # two colours that must differ do not.
  def distance(first, second)
    a = rgb(first)
    b = rgb(second)
    Math.sqrt(a.zip(b).sum { |one, other| (one - other)**2 })
  end

  def rgb(hex)
    hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "lib/contracts"
require "json"

class MobileCapabilitiesTest < Minitest::Test
  include Siberian

  SCHEMA = File.expand_path("../lib/contracts/module_manifest.schema.json", __dir__)

  # The catalogue is written twice: once as Ruby the services read, and once as
  # an enum in the manifest schema so a manifest naming a capability that does
  # not exist is refused at install rather than at build time. Two lists drift,
  # and the drift shows up as a manifest that validates and then cannot be
  # built, or one that is refused for naming something real.
  def test_the_schema_offers_exactly_the_capabilities_the_catalogue_defines
    schema = JSON.parse(File.read(SCHEMA))
    enum = schema.dig("properties", "native", "properties", "requires", "items", "enum")

    assert_equal MobileCapabilities::IDS.sort, enum.sort
  end

  def test_every_capability_names_a_package_to_install
    MobileCapabilities::CATALOGUE.each do |capability|
      refute_empty capability[:package].to_s, "#{capability[:id]} has no package"
    end
  end

  # Apple refuses a build that asks for a permission without a sentence
  # explaining it, so anything that prompts somebody carries one.
  def test_a_capability_that_interrupts_somebody_explains_itself
    MobileCapabilities::CATALOGUE.select { |capability| capability[:severity] == :high }.each do |capability|
      refute_nil capability[:usage], "#{capability[:id]} asks a lot and says nothing about why"
    end
  end

  def test_a_setting_that_is_optional_is_not_required
    required = MobileCapabilities.required_settings("push_notifications").map { |setting| setting[:key] }

    assert_empty required, "push notifications work without an Expo access token, so it cannot be required"
  end
end

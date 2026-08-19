# frozen_string_literal: true

# Integration test. Talks to a real container engine and creates real
# containers, so it is not part of the default suite. Run it with bin/test-engine.
#
# The unit suite asserts the driver sends the right requests. This asserts the
# daemon agrees with our reading of its API, which is the half a mock can never
# check.
require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("../..", __dir__))
require "lib/siberian_engine"
require "lib/siberian_engine/drivers/docker"

class DockerEngineIntegrationTest < Minitest::Test
  include Siberian

  IMAGE = "alpine:3"
  PREFIX = "sibtest"

  def setup
    @driver = Engine.driver(:docker)
    @network = "#{PREFIX}-net-#{rand(100_000)}"
    @created = []
    @driver.create_network(@network)
  end

  def teardown
    @created.each do |id|
      begin
        @driver.remove(id, force: true)
      rescue StandardError
        nil
      end
    end
    begin
      @driver.remove_network(@network)
    rescue StandardError
      nil
    end
  end

  def spec(name, overrides = {})
    Engine::ContainerSpec.new({
      name: "#{PREFIX}-#{name}-#{rand(100_000)}",
      image: IMAGE,
      role: :worker,
      aliases: [name],
      env: { "SIBERIAN_TEST" => "1" },
      labels: { "siberian.module_uuid" => "integration", "siberian.test" => "true" }
    }.merge(overrides))
  end

  def create!(spec)
    id = @driver.create(spec, network: @network)
    @created << id
    id
  end

  def test_the_daemon_reports_a_version
    refute_empty @driver.version
  end

  def test_a_container_can_be_created_started_inspected_and_removed
    id = create!(spec("lifecycle", env: { "HOLD" => "1" }))

    assert_equal :stopped, @driver.status(id), "a created container has not started yet"

    @driver.start(id)
    # alpine with no long-running command exits at once, and every container
    # carries RestartPolicy unless-stopped, so the engine may already be
    # restarting it. All three states are legitimate here.
    assert_includes %i[running stopped restarting], @driver.status(id)

    @driver.remove(id, force: true)
    @created.delete(id)
    assert_equal :absent, @driver.status(id)
  end

  def test_labels_survive_the_round_trip_and_filter_a_listing
    id = create!(spec("labelled"))

    found = @driver.list(labels: { "siberian.module_uuid" => "integration" })

    assert_includes found.map { |c| c[:id] }, id
    assert_equal "true", found.find { |c| c[:id] == id }[:labels]["siberian.test"]
  end

  def test_creating_the_same_name_twice_raises_already_exists
    name = "#{PREFIX}-dup-#{rand(100_000)}"
    create!(spec("dup", name: name))

    assert_raises(Engine::Driver::AlreadyExists) do
      @driver.create(spec("dup", name: name), network: @network)
    end
  end

  def test_removing_a_container_that_is_gone_is_not_an_error
    assert @driver.remove("sibtest-does-not-exist", force: true)
  end

  def test_status_of_an_unknown_container_is_absent
    assert_equal :absent, @driver.status("sibtest-nope-#{rand(100_000)}")
  end

  def test_an_image_that_is_absent_gets_pulled
    # busybox is small and unlikely to already be present on a fresh host.
    assert @driver.pull("busybox:stable-musl")
    assert @driver.image_present?("busybox:stable-musl")
  end

  def test_network_aliases_make_a_container_resolvable_by_its_short_name
    id = create!(spec("resolvable", image: IMAGE, aliases: ["resolvable"]))
    @driver.start(id)

    # Ask the daemon what it recorded rather than trusting what we sent.
    listed = @driver.list(labels: { "siberian.module_uuid" => "integration" })
    assert_includes listed.map { |c| c[:id] }, id
  end
end
